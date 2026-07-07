// v2.0.16: 本地 HTTP/HTTPS 代理 — 让 libmpv 视频流走优选 IP
//
// 为什么需要这个: libmpv 是 native C 库, 自己解析 DNS,
// CfOptimizerHttpOverrides (Dart HttpClient hook) 摸不到.
// 想让 libmpv 用优选 IP, 唯一办法是给它配 --http-proxy,
// 然后代理里把 host 解析到优选 IP 再连.
//
// 关键点: TLS SNI 由 libmpv (TLS client) 在握手时根据 URL 里 hostname
// 填, 跟 TCP 连接到哪个 IP 无关. 所以代理把 TCP 转到 104.16.32.1,
// libmpv 还是会发 SNI=cdn.example.com, CF edge 看 SNI 路由, cert
// 用 cdn.example.com 的, 整条链路不破.
//
// 触发条件 (全部满足才启动):
//   1. CF Worker 加速开关打开
//   2. CF Worker 域名配了
//   3. CF 优选测速开关打开
//   4. 优选 IP 已测过 (bestIps 非空) + 测速时填的 targetDomain 跟当前域名一致
// 任一不满足 → tryStart() 返回 null, 播放 URL 不走代理, 走原来的链路.

import 'dart:async';
import 'dart:io';

import 'package:luna_tv/services/cf_optimizer.dart';
import 'package:luna_tv/services/user_data_service.dart';

class VideoProxyServer {
  VideoProxyServer._();

  ServerSocket? _server;
  int _port = 0;
  bool _stopped = false;
  int _connCount = 0;
  int _tunnelCount = 0;
  int _fallbackCount = 0;
  int _errorCount = 0;

  /// 尝试启动代理.
  ///
  /// 返回 null = 条件不满足 / 启动失败, 调用方应该不配 --http-proxy,
  /// 让播放走原始 URL (v2.0.14 起的 buildProxiedUrl 路径).
  static Future<VideoProxyServer?> tryStart() async {
    // 守门 1: CF Worker 加速打开
    final workerEnabled = await UserDataService.getCfWorkerEnabled();
    if (!workerEnabled) return null;

    // 守门 2: 域名配了
    final domain = await UserDataService.getCfWorkerDomain();
    if (domain.isEmpty) return null;

    // 守门 3: CF 优选开关打开
    final optEnabled = await CfOptimizer.getEnabled();
    if (!optEnabled) return null;

    // 守门 4: 有优选 IP + 跟当前域名一致
    final bestIps = await CfOptimizer.getBestIps();
    if (bestIps.isEmpty) return null;
    final storedDomain = await CfOptimizer.getTargetDomain();
    if (storedDomain != domain) return null;

    // 全部满足, 启代理
    try {
      final s = VideoProxyServer._();
      await s._bind();
      return s;
    } catch (e) {
      return null;
    }
  }

  Future<void> _bind() async {
    // 0 = 让系统分配空闲端口, 避免跟其他 app 撞
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handleConnection, onError: (e) {
      _errorCount++;
    });
  }

  /// libmpv --http-proxy=http://127.0.0.1:PORT 用的 URL
  String get proxyUrl => 'http://127.0.0.1:$_port';
  int get port => _port;
  bool get isRunning => _server != null && !_stopped;

  // 调试用, 暴露给 player_screen 在 UI 上提示
  int get activeConnections => _connCount;
  int get tunneledRequests => _tunnelCount;
  int get fallbacks => _fallbackCount;
  int get errors => _errorCount;

  /// 关掉代理 (离开播放页 / app 退出时调用)
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }

  void _handleConnection(Socket client) {
    if (_stopped) {
      client.destroy();
      return;
    }
    _connCount++;
    final state = _ProxyState();
    StreamSubscription<List<int>>? clientSub;
    StreamSubscription<List<int>>? backendSub;

    void closeAll() {
      clientSub?.cancel();
      backendSub?.cancel();
      client.destroy();
      _connCount--;
    }

    clientSub = client.listen(
      (data) {
        try {
          _onClientData(client, state, data, (backend) {
            // 接到 backend 后, 把 client ↔ backend 串起来
            backendSub = backend.listen(
              (d) {
                try {
                  client.add(d);
                } catch (_) {
                  closeAll();
                }
              },
              onError: (_) => closeAll(),
              onDone: closeAll,
              cancelOnError: true,
            );
            // 把 client 已收到的剩余 body 推给 backend
            if (state.pendingBodyBytes.isNotEmpty) {
              backend.add(state.pendingBodyBytes);
              state.pendingBodyBytes = [];
            }
            // client → backend: 后续流过来的都推给 backend
            clientSub = client.listen(
              (d) {
                try {
                  backend.add(d);
                } catch (_) {
                  closeAll();
                }
              },
              onError: (_) => closeAll(),
              onDone: () {
                try {
                  backend.close();
                } catch (_) {}
              },
              cancelOnError: true,
            );
          }, closeAll);
        } catch (e) {
          _errorCount++;
          closeAll();
        }
      },
      onError: (_) => closeAll(),
      onDone: closeAll,
      cancelOnError: true,
    );
  }

  void _onClientData(
    Socket client,
    _ProxyState state,
    List<int> data,
    void Function(Socket backend) onBackendReady,
    void Function() closeAll,
  ) {
    state.buffer.addAll(data);
    if (state.method == null) {
      final str = String.fromCharCodes(state.buffer);
      final headerEndIdx = str.indexOf('\r\n\r\n');
      if (headerEndIdx < 0) {
        // header 还没收完, 等下一波
        return;
      }

      final headerStr = str.substring(0, headerEndIdx);
      final firstLineEnd = headerStr.indexOf('\r\n');
      if (firstLineEnd < 0) {
        _sendHttpError(client, 400, 'Bad Request', closeAll);
        return;
      }
      final firstLine = headerStr.substring(0, firstLineEnd);
      final parts = firstLine.split(' ');
      if (parts.length < 3) {
        _sendHttpError(client, 400, 'Bad Request', closeAll);
        return;
      }
      state.method = parts[0];
      state.target = parts[1];
      state.headerEnd = headerEndIdx + 4;

      // 解析所有 header (lowercase key → value)
      for (final line in headerStr.substring(firstLineEnd + 2).split('\r\n')) {
        if (line.isEmpty) break;
        final colon = line.indexOf(':');
        if (colon > 0) {
          state.headers[line.substring(0, colon).trim().toLowerCase()] =
              line.substring(colon + 1).trim();
        }
      }

      // 取出已收到的 body 片段
      final totalConsumed = state.headerEnd;
      if (state.buffer.length > totalConsumed) {
        state.pendingBodyBytes = state.buffer.sublist(totalConsumed);
      }
      state.buffer = [];

      if (state.method == 'CONNECT') {
        _handleConnect(client, state, onBackendReady, closeAll);
      } else {
        _handleHttp(client, state, onBackendReady, closeAll);
      }
    }
  }

  Future<void> _handleConnect(
    Socket client,
    _ProxyState state,
    void Function(Socket backend) onBackendReady,
    void Function() closeAll,
  ) async {
    // target = "host:port"
    final target = state.target!;
    final colon = target.lastIndexOf(':');
    final host = colon >= 0 ? target.substring(0, colon) : target;
    final port = colon >= 0
        ? (int.tryParse(target.substring(colon + 1)) ?? 443)
        : 443;

    final bestIp = CfOptimizerHttpOverrides.pickBestIpForDomain(host);
    if (bestIp != null) {
      // 走优选 IP
      try {
        final backend = await Socket.connect(bestIp, port,
            timeout: const Duration(seconds: 5));
        client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
        await client.flush();
        _tunnelCount++;
        onBackendReady(backend);
        return;
      } catch (e) {
        // 优选 IP 连不上, fallback 到原 host
        _fallbackCount++;
      }
    }

    // 没优选 / 优选连不上, fallback
    try {
      final backend = await Socket.connect(host, port,
          timeout: const Duration(seconds: 5));
      client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
      await client.flush();
      onBackendReady(backend);
    } catch (e) {
      _errorCount++;
      _sendHttpError(client, 502, 'Bad Gateway', closeAll);
    }
  }

  Future<void> _handleHttp(
    Socket client,
    _ProxyState state,
    void Function(Socket backend) onBackendReady,
    void Function() closeAll,
  ) async {
    // 非 CONNECT: 完整的代理请求, 重写 URL + Host header
    Uri uri;
    try {
      uri = Uri.parse(state.target!);
    } catch (e) {
      _sendHttpError(client, 400, 'Bad Request', closeAll);
      return;
    }
    if (!uri.hasScheme || uri.host.isEmpty) {
      _sendHttpError(client, 400, 'Bad Request', closeAll);
      return;
    }

    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final isHttps = uri.scheme == 'https';

    // HTTP 也走优选 IP 没必要 (只是 GET / 静态资源)
    // 但保险起见, 跟 HTTPS 一样查一下
    final bestIp = CfOptimizerHttpOverrides.pickBestIpForDomain(host);
    final connectHost = bestIp ?? host;

    // 拼新的 request line + headers
    final newUri = isHttps
        ? uri.replace(host: connectHost, port: port)
        : uri.replace(host: connectHost, port: port);
    final requestLine = '${state.method} $newUri HTTP/1.1';

    final headerLines = <String>[];
    var hostHeaderSet = false;
    for (final entry in state.headers.entries) {
      if (entry.key == 'host') {
        headerLines.add('Host: $host${port == 80 || port == 443 ? '' : ':$port'}');
        hostHeaderSet = true;
      } else if (entry.key == 'proxy-connection') {
        // 跳过
      } else {
        headerLines.add('${entry.key}: ${entry.value}');
      }
    }
    if (!hostHeaderSet) {
      headerLines.add('Host: $host${port == 80 || port == 443 ? '' : ':$port'}');
    }
    // HTTP/1.0 让 backend 短连接, 简化代理逻辑
    // (libmpv 通常是 HTTP/1.1 keep-alive, 但代理串接两条 keep-alive 太麻烦)

    final request =
        '$requestLine\r\n${headerLines.join('\r\n')}\r\nConnection: close\r\n\r\n';
    final reqBytes = request.codeUnits;

    try {
      final backend = await Socket.connect(connectHost, port,
          timeout: const Duration(seconds: 5));
      backend.add(reqBytes);
      if (state.pendingBodyBytes.isNotEmpty) {
        backend.add(state.pendingBodyBytes);
      }
      await backend.flush();
      _tunnelCount++;
      onBackendReady(backend);
    } catch (e) {
      _errorCount++;
      // fallback 到原 host
      if (bestIp != null && bestIp != host) {
        try {
          final backend = await Socket.connect(host, port,
              timeout: const Duration(seconds: 5));
          backend.add(reqBytes);
          if (state.pendingBodyBytes.isNotEmpty) {
            backend.add(state.pendingBodyBytes);
          }
          await backend.flush();
          _fallbackCount++;
          onBackendReady(backend);
          return;
        } catch (e2) {
          // ignore
        }
      }
      _sendHttpError(client, 502, 'Bad Gateway', closeAll);
    }
  }

  void _sendHttpError(
    Socket client,
    int code,
    String reason,
    void Function() closeAll,
  ) {
    final body = '$code $reason\r\n';
    final resp =
        'HTTP/1.1 $code $reason\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body';
    try {
      client.add(resp.codeUnits);
      client.flush().then((_) => closeAll());
    } catch (_) {
      closeAll();
    }
  }
}

class _ProxyState {
  String? method;
  String? target;
  int headerEnd = 0;
  final Map<String, String> headers = {};
  List<int> buffer = [];
  List<int> pendingBodyBytes = [];
}
