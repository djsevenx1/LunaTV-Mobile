package org.moontechlab.lunatv

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.ConnectionSpec
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

/**
 * v2.1.33: Image HTTP MethodChannel handler.
 *
 * 背景: dart:io 的 [io.HttpClient] 用 OpenSSL, 跟 CF edge zone
 *   (e.g., api.fn0.qzz.io) TLS 1.3 cipher 协商失败
 *   (SSLV3_ALERT_HANDSHAKE_FAILURE alert 40). dart:io 又**没有 public
 *   API 强制 TLS 版本** / 改 cipher 列表, **dart:io.SecureSocket.secure
 *   的 supportedProtocols 只给 ALPN (HTTP/2 vs HTTP/1.1), 不给 TLS
 *   版本** (这个参数 dart 3.4 后都限制成 List<String>), ProtocolVersion
 *   类在 Dart 3.4 都删了.
 *
 * 解法: 这个 channel 用 OkHttp (Android 系统库 Conscrypt/BoringSSL),
 *   可以强制 [ConnectionSpec.COMPATIBLE_TLS] (TLS 1.0+ 全开) 避开
 *   TLS 1.3 cipher 协商失败. cipher 列表跟所有 CF zone 都重叠.
 *
 *   优选 IP 也走这里: 之前 [_OptimizingHttpClient.getUrl] 改 URL.host
 *   为 IP + Host header 为原域名, **SNI 走的是 URL.host (IP) 不是
 *   原域名**, CF edge 用 SNI 路由 cert, 拿不到这个 SNI 的 cert
 *   → TLS 失败. 现在改用 OkHttp 的自定义 [okhttp3.Dns] 解析:
 *   overrideHost → overrideIp, **SNI 仍是原域名** → CF 路由到对的
 *   cert → TLS 成功.
 *
 * 影响范围: 只影响 [LunaImageHttp] 调的请求 (image 加载). 登录 / 测速
 *   / 视频 m3u8 探测 / video_proxy_server 都不走这里. 视频 m3u8 播放
 *   走原生 libmpv (C 库), 完全独立.
 */
class ImageHttpChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "org.moontechlab.lunatv/image_http"
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    // OkHttp client:
    //   - COMPATIBLE_TLS: TLS 1.0/1.1/1.2 全开, cipher 列表最宽, 避开
    //     dart:io TLS 1.3 cipher 协商失败问题
    //   - followRedirects(true): TMDB image URL 经常有 redirect (image.tmdb.org/t/p/...)
    //   - 重试: 不在 OkHttp 层做, 让 Dart [LunaImageHttp] 决定是否 fallback
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .connectionSpecs(
            listOf(
                // 强制兼容 TLS (1.0/1.1/1.2), 跟所有 CF zone 都兼容
                ConnectionSpec.COMPATIBLE_TLS,
                // Fallback 1: 现代 TLS (1.2/1.3), 应付大部分现代 server
                ConnectionSpec.MODERN_TLS,
            )
        )
        .build()

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "get" -> handleGet(call, result)
            "ping" -> {
                // 探活: 给 [image_url._probeWorkerHealth] 用
                result.success(mapOf("status" to "ok"))
            }
            else -> result.notImplemented()
        }
    }

    private fun handleGet(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        // 优选 IP: 可选. 如果 Dart 端把 url 已经改成 IP, 这俩是空.
        // 优先用 [overrideHost] + [overrideIp] (SNI 友好).
        val overrideHost = call.argument<String>("overrideHost")
        val overrideIp = call.argument<String>("overrideIp")

        if (url == null) {
            result.error("INVALID_ARG", "url is required", null)
            return
        }

        // 解析 URL
        val parsed = parseUrl(url)
        if (parsed == null) {
            result.error("INVALID_URL", "cannot parse url: $url", null)
            return
        }
        val (scheme, requestHost, port, pathAndQuery) = parsed

        // 优选 IP 解析:
        //   - 如果 Dart 给了 overrideHost + overrideIp, 给这个 hostname
        //     强制解析到 overrideIp (OkHttp 自定义 Dns)
        //   - 否则走系统 DNS
        val customDns = if (overrideHost != null && overrideIp != null && overrideHost == requestHost) {
            object : Dns {
                override fun lookup(hostname: String): List<InetAddress> {
                    if (hostname.equals(overrideHost, ignoreCase = true)) {
                        return try {
                            listOf(InetAddress.getByName(overrideIp))
                        } catch (e: UnknownHostException) {
                            Dns.SYSTEM.lookup(hostname)
                        }
                    }
                    return Dns.SYSTEM.lookup(hostname)
                }
            }
        } else null

        val requestClient = if (customDns != null) {
            client.newBuilder().dns(customDns).build()
        } else client

        val requestBuilder = Request.Builder()
            .url(url)
        // 加自定义 header (跳过 Host, OkHttp 不让 set)
        for ((k, v) in headers) {
            if (k.equals("Host", ignoreCase = true)) continue
            requestBuilder.addHeader(k, v)
        }
        val request = requestBuilder.build()

        // 异步跑 (OkHttp 自己有线程池, 不需要 new Thread)
        requestClient.newCall(request).enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: IOException) {
                mainHandler.post {
                    result.error("HTTP_ERROR", e.message ?: "unknown", null)
                }
            }

            override fun onResponse(call: okhttp3.Call, response: Response) {
                try {
                    val statusCode = response.code
                    val bytes = response.body?.bytes()
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "statusCode" to statusCode,
                                "body" to bytes
                            )
                        )
                    }
                } catch (e: Exception) {
                    mainHandler.post {
                        result.error("HTTP_ERROR", e.message ?: "unknown", null)
                    }
                } finally {
                    response.close()
                }
            }
        })
    }

    private data class ParsedUrl(
        val scheme: String,
        val host: String,
        val port: Int,
        val pathAndQuery: String
    )

    /**
     * 解析 url 成 (scheme, host, port, path?query). 用 java.net.URI 避免
     * 自己处理 IPv6 bracket 等边界情况.
     */
    private fun parseUrl(url: String): ParsedUrl? {
        return try {
            val uri = java.net.URI(url)
            val scheme = uri.scheme ?: return null
            val host = uri.host ?: return null
            val port = if (uri.port != -1) uri.port else if (scheme == "https") 443 else 80
            val pathAndQuery = buildString {
                append(uri.rawPath ?: "/")
                uri.rawQuery?.let { append("?"); append(it) }
            }
            ParsedUrl(scheme, host, port, pathAndQuery)
        } catch (e: Exception) {
            null
        }
    }
}
