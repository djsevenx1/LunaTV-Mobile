package org.moontechlab.lunatv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // v2.1.33: 注册 [ImageHttpChannel] (OkHttp + 强制 TLS 兼容模式),
    //   避开 dart:io TLS 1.3 cipher 跟 CF edge zone 协商失败
    //   (SSLV3_ALERT_HANDSHAKE_FAILURE). 不影响视频 m3u8 播放 (libmpv).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ImageHttpChannel(flutterEngine.dartExecutor.binaryMessenger)
    }
}
