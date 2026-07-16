package org.moontechlab.lunatv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // v2.1.33: 注册 [ImageHttpChannel] (OkHttp + 强制 TLS 兼容模式),
    //   避开 dart:io TLS 1.3 cipher 跟 CF edge zone 协商失败
    //   (SSLV3_ALERT_HANDSHAKE_FAILURE). 不影响视频 m3u8 播放 (libmpv).
    // v2.1.46: 注册 [ApkInstallChannel] — app 内建下载器下完 APK 后,
    //   用 FileProvider 把 file:// 转 content:// 调起系统 APK 安装器.
    //   跟 [ImageHttpChannel] 平行, 自己写 channel 不用第三方 pub package.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ImageHttpChannel(flutterEngine.dartExecutor.binaryMessenger)
        ApkInstallChannel(flutterEngine.dartExecutor.binaryMessenger, this)
    }
}
