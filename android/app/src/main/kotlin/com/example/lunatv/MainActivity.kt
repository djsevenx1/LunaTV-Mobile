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
        // v2.2.0+59: 屏幕常亮 channel — 播放视频时 Flutter 端调
        //   setKeepScreenOn(true) 阻止系统屏保, 离开播放页时
        //   setKeepScreenOn(false) 还原. 走 Activity.window FLAG_KEEP_SCREEN_ON,
        //   Activity 不可见时 (切后台) OS 自动失效, 不用管 lifecycle.
        KeepScreenOnChannel(flutterEngine.dartExecutor.binaryMessenger, this)
        // v2.3.6: ExoPlayer 测速 channel — 隐藏 ExoPlayer prepare() m3u8
        //   URL 测真实分片下载速度. 跟 web 版 LunaTV (hls.js FRAG_LOADED)
        //   思路 1:1 对齐, 解决 "测速 5KB/s 实际 2MB/s" 的根因.
        // v2.3.14: Dart 端已不调用, 但 channel 留作 building block (APK 里有,
        //   编译过, 跟 v2.3.9 之后一样).
        ExoSpeedTestChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
