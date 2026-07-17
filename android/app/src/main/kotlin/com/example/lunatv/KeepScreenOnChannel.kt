package org.moontechlab.lunatv

import android.app.Activity
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * v2.2.0+59: 屏幕常亮 MethodChannel handler.
 *
 * 背景: ExoPlayer (AndroidX Media3) 默认**不会**阻止屏幕休眠.
 *   Flutter `video_player` 包也没暴露 `setKeepScreenOn` 接口.
 *   用户反馈「播放一会会屏保」(Android 系统屏幕超时锁屏, 视频就看不到了),
 *   需要在播放期间主动给 Activity 加 `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`,
 *   离开播放页 (dispose) 时清掉, 恢复系统默认行为.
 *
 *   为什么不用 wakelock_plus / 第三方 pub package:
 *     - wakelock_plus 是 PowerManager.WakeLock, 锁 CPU 用的,
 *       屏幕还是会灭 (WakeLock 只保 CPU 不灭屏)
 *     - 我们要的是屏幕不灭, 不是 CPU 不休眠, 用 FLAG_KEEP_SCREEN_ON
 *       更精准, OS 会在 Activity 不可见时自动清除 (切后台/锁屏)
 *     - 跟 [ApkInstallChannel] / [ImageHttpChannel] 平行, 自己写 channel
 *       改动小, 完全可控, 不用加新 pub 依赖 (pub get 走一遍要 1-2 分钟)
 *
 * 用法 (Flutter 端):
 *   - 进入播放页 (initState / 第一次 open) → `_channel.invokeMethod('setKeepScreenOn', {'enable': true})`
 *   - 离开播放页 (dispose) → `_channel.invokeMethod('setKeepScreenOn', {'enable': false})`
 *
 *   Activity 不可见时 (切后台 / 锁屏), FLAG_KEEP_SCREEN_ON 自动失效,
 *   不用手动管 lifecycle. 切回前台时 flag 还在, 又继续 keep.
 *
 * Flutter 调用方式 (Dart 侧):
 *   ```dart
 *   static const _channel = MethodChannel('org.moontechlab.lunatv/keep_screen_on');
 *   await _channel.invokeMethod('setKeepScreenOn', {'enable': true});
 *   ```
 */
class KeepScreenOnChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "org.moontechlab.lunatv/keep_screen_on"
    }

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setKeepScreenOn" -> handleSetKeepScreenOn(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleSetKeepScreenOn(call: MethodCall, result: MethodChannel.Result) {
        val enable = call.argument<Boolean>("enable")
        if (enable == null) {
            result.error("INVALID_ARG", "enable (bool) is required", null)
            return
        }
        try {
            activity.runOnUiThread {
                if (enable) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("KEEP_SCREEN_ON_FAILED", e.message ?: "unknown error", null)
        }
    }
}
