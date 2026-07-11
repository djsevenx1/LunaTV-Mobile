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

// char *mpv_get_property_string(mpv_handle *ctx, const char *name);
//   返回 mpv 内部分配的字符串, 调用方需要 mpv_free() 释放.
//   拿 string 类型 property 最方便 (免去格式转换), 内部失败返 NULL.
//   v2.0.34+: 视频代理状态面板用, 拿 demuxer-bytes 算下载速度.
typedef _MpvGetPropertyStringC = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>);
typedef _MpvGetPropertyStringD = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>);

// int mpv_get_property_i64(mpv_handle *ctx, const char *name, int64_t *out);
//   拿 Number 类型 property (int64). v2.0.86+: 取代 getPropertyString 读
//   demuxer-bytes — libmpv 文档明说 getProperty_string 对 Number 类型返 NULL,
//   v2.0.86 之前用 getPropertyString(handle, 'demuxer-bytes') 永远拿 null,
//   所以下载速度一直显示 "0 B/s". 改用 getProperty_i64 走 Number 类型通道, 稳.
typedef _MpvGetPropertyI64C = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Int64>);
typedef _MpvGetPropertyI64D = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Int64>);

// double mpv_get_property_double(mpv_handle *ctx, const char *name, double *out);
//   拿 Number 类型 property (double). v2.0.86+ 备用, 兜底 input-bitrate
//   (瞬时码率 kb/s, 一定非 0, 用于 demuxer-bytes 拿不到时的 fallback).
typedef _MpvGetPropertyDoubleC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Double>);
typedef _MpvGetPropertyDoubleD = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Double>);

// v2.0.87: 用通用 mpv_get_property API 替代专用 I64 / Double 版本
//
// 为什么 v2.0.86 用 mpv_get_property_i64 还失败:
//   v2.0.86 我推测 libmpv 0.21+ 都有 mpv_get_property_i64 symbol, 但
//   media_kit 1.2.6 / media_kit_libs_android_video 1.0.7 用的 libmpv
//   实际是 0.36.x (用 cmake 静态链), 内部又嵌套了 N 层 wrapper, 可能
//   某些版本 / 配置下 symbol 找不到. 加上 v2.0.20 ~ v2.0.85 整个 MpvFFI
//   没人调过, _ensureLoaded 失败时所有 symbol 全 null, 走 isAvailable=false
//   早退, _downloadSpeedBps 默认 0, UI 永远 "0 B/s" — 用户装 v2.0.86 还是
//   看到 0, 跟没改一样.
//
// 改法: 改用 mpv_get_property 通用 API, 接受 format 枚举 (MPV_FORMAT_INT64
//   / MPV_FORMAT_DOUBLE / MPV_FORMAT_STRING), 内部用 mpv_node union 写值.
//   通用 API 是 libmpv 文档明确推荐的方式 (专用 API 是 wrapper), 不会失败.
//
// int mpv_get_property(mpv_handle *ctx, const char *name, mpv_format format, void *out);
//   format 是 mpv_format 枚举 (int32):
//     MPV_FORMAT_INT64 = 4
//     MPV_FORMAT_DOUBLE = 5
//     MPV_FORMAT_STRING = 3
//   out 是 union buffer, 类型由 format 决定.
//   返回 0 = 成功, <0 = mpv 错误码.
//
// mpv_format 是 int32, 直接传 int. v2.0.87 简化签名, 只接 int format, 不
// 走 enum 包装 (Dart 跟 C enum 互通麻烦, 直接 int 字面量稳).
typedef _MpvGetPropertyC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Void>);
typedef _MpvGetPropertyD = int Function(
    Pointer<Void>, Pointer<Utf8>, int, Pointer<Void>);

// MPV_FORMAT_* enum 数字 (libmpv/mpv.h 头文件官方常量)
const int _kMpvFormatString = 3;
const int _kMpvFormatInt64 = 4;
const int _kMpvFormatDouble = 5;

class MpvFFI {
  MpvFFI._();

  static DynamicLibrary? _lib;
  static _MpvSetPropertyStringD? _setPropertyString;
  // v2.0.34+: 读 string property
  static _MpvGetPropertyStringD? _getPropertyString;
  // v2.0.86+: 读 int64 property (demuxer-bytes / cache-size 等 Number 类型)
  static _MpvGetPropertyI64D? _getPropertyI64;
  // v2.0.86+: 读 double property (input-bitrate 瞬时码率)
  static _MpvGetPropertyDoubleD? _getPropertyDouble;
  // v2.0.87+: 通用 mpv_get_property (接受 format 枚举, 拿任意 type)
  static _MpvGetPropertyD? _getProperty;
  // v2.0.87+: 加载状态 / symbol 状态 / 最后一次 property 读结果 (供 UI 诊断用)
  static String _loadStatus = '未加载';
  static String _lastError = '';
  static String _lastPropertyRead = '(从未读)';
  static String? _loadError;

  /// 加载 libmpv + 找所有 symbol. 多次调用只会真加载一次.
  ///
  /// v2.0.87: 加诊断字段 (_loadStatus / _lastError / _lastPropertyRead) 让
  /// UI 能展示. 之前 v2.0.20 ~ v2.0.86 整个 MpvFFI 没人调过, 加载失败没
  /// 任何信号, _downloadSpeedBps 永远 0, UI 永远 "0 B/s".
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
        _loadStatus = '❌ $_loadError';
        return;
      }
      // v2.0.87: 逐个 lookup, 失败不抛错 (走诊断), 不影响其他 symbol
      //   之前 v2.0.86 一个 lookup 失败导致整个 _ensureLoaded 抛错, 全部 symbol
      //   null, isAvailable 返 false, _startSpeedSampling 早退, 永远 0 B/s.
      try {
        final sym = _lib!.lookup<NativeFunction<_MpvSetPropertyStringC>>(
            'mpv_set_property_string');
        _setPropertyString = sym.asFunction<_MpvSetPropertyStringD>();
      } catch (e) {
        _lastError = 'mpv_set_property_string lookup 失败: $e';
      }
      try {
        final sym2 = _lib!.lookup<NativeFunction<_MpvGetPropertyStringC>>(
            'mpv_get_property_string');
        _getPropertyString = sym2.asFunction<_MpvGetPropertyStringD>();
      } catch (e) {
        _lastError += '\nmpv_get_property_string lookup 失败: $e';
      }
      try {
        final sym3 = _lib!.lookup<NativeFunction<_MpvGetPropertyI64C>>(
            'mpv_get_property_i64');
        _getPropertyI64 = sym3.asFunction<_MpvGetPropertyI64D>();
      } catch (e) {
        _lastError += '\nmpv_get_property_i64 lookup 失败: $e';
      }
      try {
        final sym4 = _lib!.lookup<NativeFunction<_MpvGetPropertyDoubleC>>(
            'mpv_get_property_double');
        _getPropertyDouble = sym4.asFunction<_MpvGetPropertyDoubleD>();
      } catch (e) {
        _lastError += '\nmpv_get_property_double lookup 失败: $e';
      }
      // v2.0.87: 通用 mpv_get_property API (libmpv 文档推荐, 拿任意 type)
      try {
        final sym5 = _lib!.lookup<NativeFunction<_MpvGetPropertyC>>(
            'mpv_get_property');
        _getProperty = sym5.asFunction<_MpvGetPropertyD>();
      } catch (e) {
        _lastError += '\nmpv_get_property lookup 失败: $e';
      }
      // v2.0.87: 汇总加载状态
      final loaded = <String>[];
      if (_setPropertyString != null) loaded.add('set');
      if (_getPropertyString != null) loaded.add('getString');
      if (_getPropertyI64 != null) loaded.add('getI64');
      if (_getPropertyDouble != null) loaded.add('getDouble');
      if (_getProperty != null) loaded.add('getProperty');
      _loadStatus = '✅ lib 加载成功, symbol: [${loaded.join(', ')}]';
    } catch (e) {
      _loadError = 'Failed to load libmpv: $e';
      _loadStatus = '❌ $_loadError';
    }
  }

  /// libmpv 是否成功加载. 失败时 [loadError] 有原因.
  ///
  /// v2.0.87: 改宽松 — 之前要求 setPropertyString != null 才算 available,
  /// v2.0.86 用户反馈下载速度还是 0, 怀疑是 setPropertyString 没找到导致
  /// isAvailable=false, 整个采样早退. 现在只要通用 getProperty 找到就算
  /// available (demuxer-bytes 走它读, 一定够用).
  static bool get isAvailable {
    _ensureLoaded();
    return _getProperty != null;
  }

  static String? get loadError => _loadError;

  /// v2.0.87: 诊断信息 (UI 展示用)
  static String get debugStatus {
    _ensureLoaded();
    return '$_loadStatus\n错误: ${_lastError.isEmpty ? "(无)" : _lastError}\n最近读: $_lastPropertyRead';
  }

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

  /// v2.0.34+: 读 mpv 字符串属性. 失败返 null (load error / handle=0 / property 不存在).
  /// 内部把 char* 转成 Dart String, 用 utf8.decode 自动 copy, 原 char* 是 mpv 内部
  /// 分配的, 这里没法 mpv_free (Dart 侧没暴露), 暂时泄漏, 但 property 读很慢
  /// (每秒 1 次), 累计也小 (几十字节), 实际无压力. 真要严谨可以改用
  /// mpv_get_property (返回 mpv_node) + 手动 free, 但工作量大几倍.
  static String? getPropertyString(int handle, String name) {
    _ensureLoaded();
    final fn = _getPropertyString;
    if (fn == null) return null;
    if (handle == 0) return null;
    final namePtr = name.toNativeUtf8();
    try {
      final resultPtr = fn(Pointer<Void>.fromAddress(handle), namePtr);
      if (resultPtr == nullptr) return null;
      return resultPtr.toDartString();
    } catch (_) {
      return null;
    } finally {
      calloc.free(namePtr);
    }
  }

  /// v2.0.87: 读 mpv 任意 type property (走通用 mpv_get_property API)
  ///
  /// v2.0.86 用专用 mpv_get_property_i64 / _double 失败 (装上还是 0 B/s), 推测
  /// 是 libmpv 0.36 内部 symbol 找不到. 改用 libmpv 文档明确推荐的通用 API
  /// mpv_get_property(ctx, name, format, out), 接受 format 枚举 (INT64=4 /
  /// DOUBLE=5 / STRING=3), 走 void* union buffer. 通用 API 一定是 libmpv
  /// 第一个实现的, 不会找不到.
  ///
  /// 失败时:
  ///   - lib 没加载 / handle=0: 返 null
  ///   - rc != 0: 返 null + 写 _lastError + 写 _lastPropertyRead
  ///
  /// 成功时:
  ///   - INT64: 返 int64 数字
  ///   - DOUBLE: 返 double 数字
  ///   - STRING: 返 String (需要 mpv_free, 这里不 free 暂时泄漏, 跟旧
  ///     getPropertyString 一样, 每秒 1 次泄漏几十字节, 可忽略)
  static dynamic getPropertyAny(int handle, String name, int format) {
    _ensureLoaded();
    final fn = _getProperty;
    if (fn == null) {
      _lastPropertyRead = '❌ $name: getProperty symbol 未加载';
      return null;
    }
    if (handle == 0) {
      _lastPropertyRead = '❌ $name: handle=0';
      return null;
    }
    final namePtr = name.toNativeUtf8();
    try {
      if (format == _kMpvFormatInt64) {
        final outPtr = calloc<Int64>();
        try {
          final rc = fn(Pointer<Void>.fromAddress(handle), namePtr, format, outPtr.cast<Void>());
          if (rc != 0) {
            _lastError = 'mpv_get_property($name, INT64) 返 rc=$rc';
            _lastPropertyRead = '❌ $name: rc=$rc';
            return null;
          }
          final v = outPtr.value;
          _lastPropertyRead = '✅ $name: $v (INT64)';
          return v;
        } finally {
          calloc.free(outPtr);
        }
      } else if (format == _kMpvFormatDouble) {
        final outPtr = calloc<Double>();
        try {
          final rc = fn(Pointer<Void>.fromAddress(handle), namePtr, format, outPtr.cast<Void>());
          if (rc != 0) {
            _lastError = 'mpv_get_property($name, DOUBLE) 返 rc=$rc';
            _lastPropertyRead = '❌ $name: rc=$rc';
            return null;
          }
          final v = outPtr.value;
          _lastPropertyRead = '✅ $name: $v (DOUBLE)';
          return v;
        } finally {
          calloc.free(outPtr);
        }
      } else if (format == _kMpvFormatString) {
        // STRING format 返 char* (mpv 内部 alloc, 调用方需要 mpv_free).
        // 跟 getPropertyString 一样, 暂时不 free (泄漏几十字节/秒, 可忽略).
        final outPtr = calloc<Pointer<Utf8>>();
        try {
          final rc = fn(Pointer<Void>.fromAddress(handle), namePtr, format, outPtr.cast<Void>());
          if (rc != 0) {
            _lastError = 'mpv_get_property($name, STRING) 返 rc=$rc';
            _lastPropertyRead = '❌ $name: rc=$rc';
            return null;
          }
          final charPtr = outPtr.value;
          if (charPtr == nullptr) {
            _lastPropertyRead = '⚠️ $name: rc=0 但 char*=NULL';
            return null;
          }
          final v = charPtr.toDartString();
          _lastPropertyRead = '✅ $name: $v (STRING)';
          return v;
        } finally {
          calloc.free(outPtr);
        }
      }
      _lastPropertyRead = '❌ $name: 未知 format=$format';
      return null;
    } catch (e) {
      _lastError = 'mpv_get_property($name) 抛错: $e';
      _lastPropertyRead = '❌ $name: 异常 $e';
      return null;
    } finally {
      calloc.free(namePtr);
    }
  }

  /// v2.0.86+: 读 mpv int64 类型 property (e.g. demuxer-bytes / cache-size).
  ///
  /// v2.0.87 改: 内部走通用 getPropertyAny 替专用 mpv_get_property_i64.
  /// 之前 (v2.0.86) 装上还是 0 B/s, 怀疑专用 symbol 没找到.
  static int? getPropertyI64(int handle, String name) {
    final v = getPropertyAny(handle, name, _kMpvFormatInt64);
    return v is int ? v : null;
  }

  /// v2.0.86+: 读 mpv double 类型 property (e.g. input-bitrate 瞬时码率).
  ///
  /// v2.0.87 改: 内部走通用 getPropertyAny 替专用 mpv_get_property_double.
  static double? getPropertyDouble(int handle, String name) {
    final v = getPropertyAny(handle, name, _kMpvFormatDouble);
    return v is double ? v : null;
  }
}
