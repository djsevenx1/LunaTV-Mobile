// v2.1.33: LunaImageHttp — Android MethodChannel + OkHttp 路径, 避开 dart:io
//   TLS 1.3 cipher 跟 CF edge zone 协商失败 (SSLV3_ALERT_HANDSHAKE_FAILURE).
//
// 背景:
//   - dart:io [HttpClient] 用 OpenSSL, 跟 CF edge zone (e.g., api.fn0.qzz.io)
//     TLS 1.3 cipher 列表没有重叠 → 服务端发 SSLV3_ALERT_HANDSHAKE_FAILURE
//     → image 加载全挂
//   - dart:io **没有 public API 强制 TLS 版本** / 改 cipher 列表
//     (ProtocolVersion 类 dart 3.4 删了, SecureSocket.secure.supportedProtocols
//      只给 ALPN, SecurityContext.minimumTlsProtocolVersion 只设 floor)
//   - Android MethodChannel 调原生 OkHttp (用系统 Conscrypt/BoringSSL, 全
//     cipher 支持), OkHttpBuilder.connectionSpecs 加 COMPATIBLE_TLS (TLS 1.0+)
//     避开 TLS 1.3 cipher 协商失败
//
// 实现:
//   - [LunaImageHttp] 继承 [http.BaseClient] (http 1.x 的标准模式: 包一个内层
//     [http.Client] 兜底). 内层默认是 [http.IOClient] (dart:io)
//   - Android + GET: 走 [MethodChannel] 让原生 OkHttp 处理
//   - iOS / 其他 / 非 GET / 原生失败: 退到 [_inner.send] (dart:io 走系统 DNS,
//     跟 v2.1.25~32 行为兼容, image_url._probeWorkerHealth 自己处理 fallback)
//
// 影响范围:
//   - 由 [LunaCacheManager] 通过 [HttpFileService] 间接使用 (跨 17 个
//     [CachedNetworkImage] 调用点 — 3.4.1 没 httpClient 参数了, 走 cacheManager)
//   - 视频 m3u8 播放走原生 libmpv (C 库), 完全独立, 不受影响
//
// 优选 IP:
//   - 调用 [CfOptimizerHttpOverrides] 公共 getter 拿 targetDomain + 优选 IP,
//     传给 channel 当 overrideHost + overrideIp
//   - OkHttp 用自定义 [okhttp3.Dns] 解析 overrideHost → overrideIp, SNI
//     仍是原域名 → CF 路由到对的 cert → TLS 成功
//   - 没配优选 IP 时, overrideHost/overrideIp 都是 null, 走系统 DNS

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:luna_tv/services/cf_optimizer.dart';

class LunaImageHttp extends http.BaseClient {
  static const _channel = MethodChannel('org.moontechlab.lunatv/image_http');

  // v2.1.33: 内层 http.Client — 用于非 Android / 非 GET / 原生失败时的兜底
  //   - 内层默认 [IOClient] 走 dart:io (跟 v2.1.25~32 行为一致)
  //   - 构造函数允许注入自定义 client (测试用)
  final http.Client _inner;

  // v2.1.33: 单例 — OkHttp client 在 Kotlin 端是单例, 这里也单例避免重复
  //   跨所有 [CachedNetworkImage] 共享同一个 [LunaImageHttp] 实例
  static final LunaImageHttp _instance = LunaImageHttp._(IOClient());
  factory LunaImageHttp() => _instance;
  LunaImageHttp._(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Android + GET 才走 MethodChannel. iOS / 其他 / 非 GET / 失败 → [_inner].
    if (Platform.isAndroid &&
        request is http.Request &&
        request.method == 'GET') {
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'get',
          {
            'url': request.url.toString(),
            'headers': request.headers,
            ...?_getIpOverride(request.url),
          },
        );
        if (result == null) {
          throw const FormatException('null result from native');
        }
        final statusCode = result['statusCode'] as int? ?? 500;
        final body = result['body'] as Uint8List?;
        return http.StreamedResponse(
          Stream.value(body ?? Uint8List(0)),
          statusCode,
          contentLength: body?.length,
        );
      } catch (e) {
        // v2.1.33: 失败时退到内层 [http.Client] (dart:io), 让上层
        //   [CachedNetworkImage] 决定是否 fallback (走直连 / 显示 errorWidget).
        //   跟 v2.1.25~32 行为兼容. 这里不重新抛 e 是因为 [BaseClient.send]
        //   抛异常会被 [CachedNetworkImage] 当成"网络失败", 显示 errorWidget.
        //   如果想看 log, 可以打开 assert:
        // assert(() { print('[LunaImageHttp] native failed: $e'); return true; }());
      }
    }
    return _inner.send(request);
  }

  /// v2.1.33: 拿到 [url] 对应的优选 IP override (overrideHost + overrideIp).
  ///   - 命中 worker domain 才返, 否则 null
  ///   - 优选开关关 / 没优选 IP / 优选 IP 是空 → null
  ///   - overrideHost 永远是 worker 域名 (用于 SNI), overrideIp 是要连的 IP
  Map<String, String>? _getIpOverride(Uri url) {
    if (!CfOptimizerHttpOverrides.isFeatureEnabled()) return null;
    final target = CfOptimizerHttpOverrides.getTargetDomain();
    if (target == null || target.isEmpty) return null;
    if (url.host.toLowerCase() != target.toLowerCase()) return null;

    final manual = CfOptimizerHttpOverrides.getResolvedManualIp();
    if (manual != null && manual.isNotEmpty) {
      return {'overrideHost': target, 'overrideIp': manual};
    }

    final ips = CfOptimizerHttpOverrides.getBestIps();
    if (ips == null || ips.isEmpty) return null;
    return {'overrideHost': target, 'overrideIp': ips.first};
  }
}
