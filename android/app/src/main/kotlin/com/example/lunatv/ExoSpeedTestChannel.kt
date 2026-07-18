package org.moontechlab.lunatv

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * v2.3.6: 用隐藏 ExoPlayer 测速的 MethodChannel handler.
 *
 * 背景: 之前 v2.3.3-2.3.5 用 Dart 端 Dio Range 请求测速, 经常显示
 *   5KB/s 但实际播放 1-2MB/s (CDN 对 Range 请求限速 / 路径不一致 /
 *   取的是 init.mp4 之类小段). Web 版 LunaTV
 *   (https://github.com/djsevenx1/LunaTV) 的方案是用 hls.js 真实加载
 *   m3u8 到隐藏 video 元素, 监听 `FRAG_LOADING` -> `FRAG_LOADED` 事件,
 *   从 `data.payload.byteLength` 算实际分片速度 — 测的是真实视频分片
 *   下载速度, 跟播放走的链路完全一样.
 *
 * 这里用 AndroidX Media3 ExoPlayer 实现同样的思路: 创建隐藏 ExoPlayer,
 *   `prepare()` m3u8 URL (不 `play()`, 不渲染, 没有 Surface 也能下载),
 *   监听 `AnalyticsListener.onLoadStarted` / `onLoadCompleted` 算第一个
 *   实际分片的下载速度. 跟 web 版 hls.js 的测量方式 1:1 对齐.
 *
 * 行为细节:
 *   - 输入: {url: String, timeoutMs: int} (默认 5000ms)
 *   - 输出: {success: bool, downloadSpeed: double (KB/s),
 *           latencyMs: int, bytesLoaded: long, error?: String}
 *   - downloadSpeed: 第一个非 manifest load (> 32KB) 的 bytes / time.
 *     manifest 本身只有几 KB, 阈值 32KB 过滤掉, 拿到的就是真实分片.
 *     跟 web 版 hls.js `FRAG_LOADED` 的 `data.payload.byteLength`
 *     测量等价.
 *   - 失败 / 超时: success=false, downloadSpeed=0
 *   - 每次测试独立一个 ExoPlayer, 测完 `release()` 释放. 测速过程
 *     在专用的 HandlerThread (ExoSpeedTest) 上跑, 不阻塞 Flutter UI.
 *
 * 跟 Dart 端 [M3U8Service] 协作:
 *   - 主路径: Dart 调 ExoSpeedTest.testSpeed() 拿 KB/s.
 *     这是跟播放走同一条链路的真实速度, 解决 "测速 5KB/s 播放 2MB/s" 的根因.
 *   - 兜底: ExoPlayer 失败 (channel 没注册 / 设备不支持 / 解析报错 /
 *     timeout) 时, Dart 端降级到 Range 抽样测速.
 */
@UnstableApi
class ExoSpeedTestChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "org.moontechlab.lunatv/exo_speed_test"
    }

    // 专用后台线程, 避免阻塞 Flutter UI 线程.
    // ExoPlayer 内部有自己的 playback thread, 但 listener 回调也会跑到这里.
    private val handlerThread = HandlerThread("ExoSpeedTest").apply { start() }
    private val handler = Handler(handlerThread.looper)

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "testSpeed" -> handleTestSpeed(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleTestSpeed(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url == null) {
            result.error("INVALID_ARG", "url required", null)
            return
        }
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000

        // 测速本身是阻塞的 (轮询 wait loop), 扔到后台线程跑
        handler.post {
            val r = runSpeedTest(url, timeoutMs.toLong())
            result.success(r)
        }
    }

    private fun runSpeedTest(url: String, timeoutMs: Long): Map<String, Any> {
        var player: ExoPlayer? = null
        val startTime = System.currentTimeMillis()

        // 测第一个非 manifest 的 load (即真实分片) 的下载时间
        val firstLoadStart = AtomicLong(0L)
        val firstLoadEnd = AtomicLong(0L)
        val firstLoadBytes = AtomicLong(0L)
        val loadDone = AtomicBoolean(false)
        val errored = AtomicBoolean(false)

        // 记录 prepare 到首个 load started 的耗时, 近似 latency
        // (跟真实播放的"打开页面到首帧"时间一致)
        val prepareToFirstLoad = AtomicLong(0L)

        return try {
            val httpFactory = DefaultHttpDataSource.Factory()
                .setUserAgent("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
                .setConnectTimeoutMs(5000)
                .setReadTimeoutMs(10000)
                .setAllowCrossProtocolRedirects(true)
                .setDefaultRequestProperties(
                    mapOf(
                        "Accept" to "*/*",
                        "Accept-Language" to "zh-CN,zh;q=0.9,en;q=0.8",
                    )
                )

            // DefaultDataSource.Factory 包裹 httpFactory, 内部按 URL 协议
            //   选 DataSource (http / https / file / content / raw). 跟
            //   ExoPlayer 播放 m3u8 时走的数据源一致, 保证测速链路跟
            //   播放链路完全相同.
            val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)

            player = ExoPlayer.Builder(context)
                .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
                .build()

            player.addAnalyticsListener(object : AnalyticsListener {
                override fun onLoadStarted(
                    eventTime: AnalyticsListener.EventTime,
                    loadEventInfo: LoadEventInfo,
                    mediaLoadData: MediaLoadData,
                ) {
                    if (firstLoadStart.get() == 0L) {
                        firstLoadStart.set(System.currentTimeMillis())
                        prepareToFirstLoad.set(firstLoadStart.get() - startTime)
                    }
                }

                override fun onLoadCompleted(
                    eventTime: AnalyticsListener.EventTime,
                    loadEventInfo: LoadEventInfo,
                    mediaLoadData: MediaLoadData,
                ) {
                    val bytes = loadEventInfo.bytesLoaded
                    // 阈值 32KB: m3u8 manifest 本身只有几 KB, 第一个
                    //   > 32KB 的 load 几乎肯定是真实分片 (hls.js
                    //   FRAG_LOADED 等价). 拿这个 load 的 bytes / time
                    //   算速度, 跟 web LunaTV 思路完全一致.
                    if (firstLoadStart.get() > 0L && !loadDone.get() && bytes > 32 * 1024) {
                        firstLoadEnd.set(System.currentTimeMillis())
                        firstLoadBytes.set(bytes)
                        loadDone.set(true)
                    }
                }

                override fun onLoadError(
                    eventTime: AnalyticsListener.EventTime,
                    loadEventInfo: LoadEventInfo,
                    mediaLoadData: MediaLoadData,
                    error: IOException,
                    wasCanceled: Boolean,
                ) {
                    errored.set(true)
                }
            })

            player.addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    errored.set(true)
                }
            })

            val mediaItem = MediaItem.fromUri(url)
            player.setMediaItem(mediaItem)
            player.prepare()
            // playWhenReady=false: 不开始播放, 只让 ExoPlayer 下载 manifest
            //   + 选 variant + 下首个分片, 然后我们拿分片大小 / 时间算速度.
            //   跟 web 版 hls.js "加载但不播放" 一致.
            player.playWhenReady = false

            // 阻塞等待首个分片 load 完成 / 报错 / 超时
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline && !loadDone.get() && !errored.get()) {
                Thread.sleep(50)
            }

            val totalMs = System.currentTimeMillis() - startTime
            if (loadDone.get() && firstLoadBytes.get() > 0) {
                val segmentMs = (firstLoadEnd.get() - firstLoadStart.get()).coerceAtLeast(1L)
                val speedKBps = (firstLoadBytes.get() / 1024.0) / (segmentMs / 1000.0)
                mapOf(
                    "success" to true,
                    "downloadSpeed" to speedKBps,
                    "latencyMs" to totalMs,
                    "bytesLoaded" to firstLoadBytes.get(),
                    "prepareMs" to prepareToFirstLoad.get(),
                )
            } else {
                mapOf(
                    "success" to false,
                    "downloadSpeed" to 0.0,
                    "latencyMs" to totalMs,
                    "bytesLoaded" to 0L,
                )
            }
        } catch (e: Exception) {
            mapOf(
                "success" to false,
                "downloadSpeed" to 0.0,
                "latencyMs" to (System.currentTimeMillis() - startTime),
                "bytesLoaded" to 0L,
                "error" to (e.message ?: e.javaClass.simpleName),
            )
        } finally {
            // 必释放 ExoPlayer, 不然 OOM
            try { player?.release() } catch (_: Exception) {}
        }
    }
}
