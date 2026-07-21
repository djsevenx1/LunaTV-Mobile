package org.moontechlab.lunatv

import android.content.Context
import android.media.AudioManager
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// v2.5.18: 屏蔽系统音量弹窗的物理音量键拦截.
///
/// 背景:
///   - 用户反馈「播放时调节音量要屏蔽系统音量调节窗口安卓16」.
///   - 之前 `volume_controller` 包的 `showSystemUI = false` 只对
///     `setVolume()` 这种软调音量有效. 物理音量键 (KEYCODE_VOLUME_UP /
///     DOWN) 走 `Activity.dispatchKeyEvent` → 系统默认 `AudioManager`
///     调 `adjustStreamVolume` 并弹系统音量条, **绕过 volume_controller**.
///   - 升级 `volume_controller` 到 3.4.4 修了软调的 SystemUI 行为, 但
///     物理键仍走 Activity, 没法在 Dart 层拦截 — 必须在 Kotlin 层拦.
///
/// 实现:
///   - `MainActivity.dispatchKeyEvent` 拦截 `KEYCODE_VOLUME_UP` /
///     `KEYCODE_VOLUME_DOWN` / `KEYCODE_VOLUME_MUTE`, 触发 Dart 端
///     「up / down / mute」 事件.
///   - 物理键返回 `true` 表示消费, **不让系统默认处理**, 避免弹
///     系统音量条. Dart 端收到事件后自己调 `setVolume()` (走 3.4.4
///     的 showSystemUI=false 路径, 不弹).
///   - 非音量键 (上下左右返回等) 走 super.dispatchKeyEvent, 不影响
///     其他物理键 (TV 盒子用的方向键 / 红外遥控).
///
/// 注意: 只在 `enabled = true` 时拦截, setEnabled(false) 时正常
/// 透传物理键 (e.g. 用户离开播放页, 音量键应该走系统默认).
object VolumeKeyChannel {
    private const val CHANNEL_NAME = "org.moontechlab.lunatv/volume_key"

    @Volatile
    private var enabled: Boolean = false

    @Volatile
    private var channel: MethodChannel? = null

    @Volatile
    private var audioManager: AudioManager? = null

    /**
     * FlutterEngine 启动时调 — 注册 MethodChannel + 缓存 AudioManager.
     */
    fun configure(engine: FlutterEngine, activity: FlutterActivity) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    val value = call.argument<Boolean>("enabled") ?: false
                    setEnabled(value)
                    result.success(null)
                }
                "getMaxVolume" -> {
                    val am = audioManager ?: activity.applicationContext
                        .getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    result.success(maxVol)
                }
                else -> result.notImplemented()
            }
        }
        audioManager = activity.applicationContext
            .getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    /**
     * v2.5.18: setEnabled 控制拦截开关.
     * - true: 物理音量键消费, 转发到 Dart 端 (不放行到系统, 不弹音量条)
     * - false: 物理音量键透传系统, 走系统默认 adjustStreamVolume + 弹音量条
     */
    fun setEnabled(value: Boolean) {
        enabled = value
    }

    /**
     * 给 MainActivity 的 dispatchKeyEvent 调用.
     * 返回 true 表示已消费 (拦截了系统音量条), false 表示透传.
     */
    fun onKeyEvent(event: KeyEvent): Boolean {
        // 只拦截按下 (ACTION_DOWN) — 抬起 ACTION_UP 让系统正常处理,
        // 否则长按音量键会持续触发, 一次调节一下, 体验差.
        if (event.action != KeyEvent.ACTION_DOWN) return false
        if (!enabled) return false

        val direction: String? = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "up"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "down"
            KeyEvent.KEYCODE_VOLUME_MUTE -> "mute"
            else -> null
        }
        if (direction == null) return false

        // 通知 Dart 端 — channel?.invokeMethod 内部切到主线程, 不会
        // throw. 物理键拦截后系统不调 adjustStreamVolume, 不弹音量条.
        channel?.invokeMethod("onVolumeKey", direction)
        return true
    }
}
