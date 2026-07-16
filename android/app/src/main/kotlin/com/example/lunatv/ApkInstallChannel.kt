package org.moontechlab.lunatv

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * v2.1.46: APK 安装 MethodChannel handler.
 *
 * 背景: app 内建下载器下完 APK 后, 要调起系统 APK 安装器 (用户在
 *   「更新」弹窗点「下载并安装」). Android 7+ (API 24+) 严格模式禁止
 *   跨进程 file:// URI 暴露 (FileUriExposedException), 必须用
 *   [FileProvider] 把 file:// 转 content:// 才能跨进程传给安装器.
 *   androidx.core.content.FileProvider 是 Flutter Android 模板
 *   默认依赖, 直接可用, 不用加新 pub package.
 *
 *   设计选择: 不依赖 [android_intent_plus] / [install_plugin] 等
 *   第三方 pub package, 自己写 channel 跟 [ImageHttpChannel] 平行,
 *   改动小, 完全可控.
 *
 * 用法 (Flutter 端): 把下载好的 APK 存到
 *   [path_provider.getTemporaryDirectory()] (即
 *   /data/data/<pkg>/cache/), 调
 *   `_channel.invokeMethod('installApk', {'path': <absPath>})`,
 *   channel 内部用 FileProvider.getUriForFile + Intent.ACTION_VIEW
 *   + application/vnd.android.package-archive MIME, 调起系统
 *   APK 安装器 (用户可能在选择器里看到「包安装程序」+ 「文件管理器」
 *   等多个选项, 但 Android 系统默认走「包安装程序」).
 *
 * FileProvider authorities 跟 AndroidManifest.xml 里配的对应:
 *   ${applicationId}.fileprovider = org.moontechlab.lunatv.fileprovider
 */
class ApkInstallChannel(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "org.moontechlab.lunatv/apk_install"
    }

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> handleInstallApk(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleInstallApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("INVALID_ARG", "path is required", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("FILE_NOT_FOUND", "APK file not found: $path", null)
            return
        }
        try {
            val authority = "${context.packageName}.fileprovider"
            val uri = FileProvider.getUriForFile(context, authority, file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            result.success(null)
        } catch (e: android.content.ActivityNotFoundException) {
            // 设备没装能处理 ACTION_VIEW + application/vnd.android.package-archive
            // 的 app (极罕见, 现代 Android 一定有「包安装程序」, 但用户可能
            // 在定制 ROM 里禁用). 给个明确错误让 Flutter 端 SnackBar 提示.
            result.error(
                "NO_INSTALLER",
                "系统找不到 APK 安装器 (极罕见, 检查设备或上报)",
                null
            )
        } catch (e: IllegalArgumentException) {
            // FileProvider.getUriForFile 抛 IllegalArgumentException 当
            // file 路径不在 file_paths.xml 白名单里. 99% 是配置错误,
            // 提醒用户检查 AndroidManifest.
            result.error(
                "PROVIDER_PATH_MISSING",
                "FileProvider 路径未授权: ${e.message}",
                null
            )
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message ?: "unknown error", null)
        }
    }
}
