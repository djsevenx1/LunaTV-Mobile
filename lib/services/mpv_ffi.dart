// v2.0.20: 用 dart:ffi 直接调 libmpv 的 mpv_set_property_string
//
// 为什么需要这个:
//   media_kit 1.2.6 (pub.dev 上最新的 stable) 的 Player 类只暴露高层 API
//   (setVolume / setRate / open / play / pause ...), 没有 setProperty 也没
//   有 command 方法. v2.0.16 用 setProperty 编不过 (错), v2.0.18 / v2.0.19
//   改用 command 还是编不过 (同样错), 整个本地代理 + race-dial 功能就废了.
//
//   退路: media_kit 的 Player.handle 暴露 libmpv 的 mpv_handle* (Future<int>),
//   我们拿到这个 handle, 用 dart:ffi 直接 dlopen libmpv.so 调
//   mpv_set_property_string(ctx, "http-proxy", "http://127.0.0.1:PORT"),
//   libmpv 就会把所有 HTTP/HTTPS 流量走代理.
//
// libmpv 加载:
//   - Android: libmpv.so 在 app 的 libs/<abi>/ 下面, dlopen("libmpv.so") 就行
//   - Linux: 系统包 libmpv-dev
//   - Windows: media_kit 带的 mpv-2.dll
//   - macOS / iOS: 走 process() 拿已经加载的符号 (media_kit 启动时加载过)
//
// 失败兜底:
//   任何一步挂 (找不到 lib, 找不到 symbol, handle 是 0) → 返 -1.
//   调用方应该当失败处理, 把代理 stop 掉, 走原来的 buildProxiedUrl 链路.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// int mpv_set_property_string(mpv_handle *ctx, const char *name, const char *value);
typedef _MpvSetPropertyStringC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _MpvSetPropertyStringD = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

class MpvFFI {
  MpvFFI._();

  static DynamicLibrary? _lib;
  static _MpvSetPropertyStringD? _setPropertyString;
  static String? _loadError;

  /// 加载 libmpv + 找 mpv_set_property_string symbol. 多次调用只会真加载一次.
  static void _ensureLoaded() {
    if (_lib != null || _loadError != null) return;
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        // Android: media_kit_libs_video 把 libmpv.so 打到 app 的 libs/<abi>/,
        // dlopen 默认从那里找. Linux 系统装 libmpv-dev 即可.
        _lib = DynamicLibrary.open('libmpv.so');
      } else if (Platform.isWindows) {
        _lib = DynamicLibrary.open('libmpv-2.dll');
      } else if (Platform.isMacOS || Platform.isIOS) {
        // Apple 平台: media_kit 把 libmpv 静态链进自己的 framework, 符号已经在
        // 当前进程的符号表里, 用 process() 拿就行.
        _lib = DynamicLibrary.process();
      } else {
        _loadError = 'libmpv not supported on ${Platform.operatingSystem}';
        return;
      }
      final sym = _lib!.lookup<NativeFunction<_MpvSetPropertyStringC>>(
          'mpv_set_property_string');
      _setPropertyString = sym.asFunction<_MpvSetPropertyStringD>();
    } catch (e) {
      _loadError = 'Failed to load libmpv: $e';
    }
  }

  /// libmpv 是否成功加载. 失败时 [loadError] 有原因.
  static bool get isAvailable {
    _ensureLoaded();
    return _setPropertyString != null;
  }

  static String? get loadError => _loadError;

  /// 设置 mpv 字符串属性. 等价于 mpv CLI 的 `--<name>=<value>`.
  ///
  /// [handle] 是 [Player.handle] 返回的 int (mpv_handle* 指针地址).
  /// 返回 0 = 成功, <0 = mpv 错误码 (常见: -2 = 找不到 property, -3 = property 只读).
  /// 返回 -1 = 我们这边没加载成功 (看 [loadError]).
  static int setPropertyString(int handle, String name, String value) {
    _ensureLoaded();
    final fn = _setPropertyString;
    if (fn == null) return -1;
    if (handle == 0) return -1;
    final namePtr = name.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    try {
      return fn(Pointer<Void>.fromAddress(handle), namePtr, valuePtr);
    } finally {
      calloc.free(namePtr);
      calloc.free(valuePtr);
    }
  }
}
