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
// v2.0.19: 借鉴 cmliu/edgetunnel 的 "预加载竞速拨号" — 同时拨 Top3 优选 IP,
// 首个连上的就用, 避免单 IP 抽风. 单 IP 拨号 v2.0.16 5s 超时经常触发,
// 改成并发拨后, 整体连接耗时基本等于最快 IP 的延迟.
//
// v2.0.34: 触发条件大改 — 改用 v2.0.32 手动优选 IP / 优选域名 字段,
//   不再依赖 v2.0.30 已砍的"优选测速"开关 + bestIps 缓存.
//   原因: 用户反馈"worker 不走优选, 速度不快吧" — worker 本身不能选 POP,
//   设备到 CF 边缘的 TCP 路由还是看系统 DNS + 路由表, 优选 IP 的价值就在
//   强制走快的 CF POP. 之前 tryStart 依赖 optEnabled+bestIps, 测速功能
//   砍了之后视频代理实际上永远起不来, 失去了优选 IP 的加速效果.
//   现在手动优选 IP (用户填 cf.877774.xyz 这类域名也行) 配上就能起代理.
//
// 触发条件 (v2.0.34, 全部满足才启动):
//   1. CF Worker 加速开关打开
//   2. CF Worker 域名配了
//   3. 手动优选 IP 配了 + 已解析 (v2.0.32 启动时 + 5min 周期 resolve)
// 任一不满足 → tryStart() 返回 null, 播放 URL 不走代理, 走原来的链路.

import 'dart:async';
import 'dart:io';

import 'package:luna_tv/services/video_proxy_log.dart';

import 'package:luna_tv/services/cf_optimizer.dart' show CfOptimizerHttpOverrides;
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
  int _raceWinCount = 0; // v2.0.19: 走预加载竞速拨号成功的次数

  /// 尝试启动代理.
  ///
  /// 返回 null = 条件不满足 / 启动失败, 调用方应该不配 --http-proxy,
  /// 让播放走原始 URL (v2.0.14 起的 buildProxiedUrl 路径).
  ///
  /// v2.0.34 改: 门从 4 个砍到 3 个
  ///   - 去掉 "优选测速开关打开" (v2.0.30 已砍)
  ///   - 去掉 "bestIps 非空 + targetDomain 一致" (依赖测速, 测速已砍)
  ///   - 改成 "手动优选 IP 配了 + 已 resolve" (v2.0.32 字段)
  ///   _resolvedManualIp 在 App 启动时 + 5min 周期 resolve, 进入播放页时
  ///   大概率已经拿到, 万一没拿到 (刚开机瞬开 app) 走 tryStart 返回 null,
  ///   libmpv 走原 URL, 不影响播放.
  static Future<VideoProxyServer?> tryStart() async {
    // 守门 1: CF Worker 加速打开
    final workerEnabled = await UserDataService.getCfWorkerEnabled();
    if (!workerEnabled) return null;

    // 守门 2: 域名配了
    final domain = await UserDataService.getCfWorkerDomain();
    if (domain.isEmpty) return null;

    // 守门 3 (v2.0.34): 手动优选 IP 已解析
    //   _resolvedManualIp 在 v2.0.32 resolveManualPreferred() 后非空
    //   - IPv4 模式: setManualPreferredIp 时立即设
    //   - 域名模式: 启动时 + 5min 周期 resolve
    //   null = 没配 / 刚启动还没 resolve 完 / 解析失败
    final resolvedIp = CfOptimizerHttpOverrides.getResolvedManualIp();
    if (resolvedIp == null || resolvedIp.isEmpty) return null;

    // 全部满足, 启代理
    try {
      final s = VideoProxyServer._();
      await s._bind();
      // ignore: avoid_print
      VideoProxyLog.append('[VideoProxy] tryStart 成功: bind 127.0.0.1:${s._port}');
      return s;
    } catch (e, st) {
      // v2.0.39: 不再静默吞, 打印详细原因. _bind() 失败一般是:
      //   - 端口被占 (极少见, 0 是系统分配空闲端口)
      //   - 系统限制 ServerSocket (Android 14+ 沙箱)
      //   - 已有 _videoProxy 没释放 (跨页面残留, _ensureVideoProxy 守门)
      //   - 异常 OS 资源耗尽
      // ignore: avoid_print
      VideoProxyLog.append('[VideoProxy] tryStart bind 失败: $e\n$st');
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
  int get raceWins => _raceWinCount;

  /// 关掉代理 (离开播放页 / app 退出时调用)
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }

  /// v2.0.19: 借鉴 cmliu/edgetunnel "预加载竞速拨号"
  ///
  /// 同时拨 [candidateIps] 里的所有 IP, 首个连上的 Socket 立刻返回.
  /// 全部失败 → fallback 到 [originalHost] 再试一次.
  ///
  /// 跟单 IP 拨号 (v2.0.16) 的对比:
  ///   - v2.0.16: 1 IP × 5s 超时, 抽风时整个播放都卡
  ///   - v2.0.19: 3 IP 并发, 整体耗时 ≈ 最快 IP 的延迟 (100~500ms)
  ///   - 失败兜底: 全部 IP 都不行 → 连原 host (走 CF 自己的 DNS 解析)
  /// v2.0.21 修: 输的 socket 必须 destroy
  ///   旧代码 .then((socket) { if (!completer.isCompleted) completer.complete(socket); })
  ///   输的 .then 也触发, completer 已被完成 → 静默丢 socket, **FD 泄漏**:
  ///     - 长 HLS 几百段, 每段 CONNECT 触发 3 个 Socket.connect
  ///     - 输的 2 个 socket 没人 destroy, 直到 OS 超时(分钟级)或进程退出才回收
  ///     - 移动端 FD 上限本来就紧 (Android 软限 ~1024), 累积到一定程度
  ///       Socket.connect 开始失败 → 视频起播变慢 / 部分段 502
  ///   修法: 输的 socket 立即 destroy, 配套用 winnerChosen 标志区分
  ///   "已胜出" 还是 "真失败", 防止 winner 已返回后输的 catchError
  ///   还把 errorCount 累上去把 completer 误覆盖成错误.
  ///
  /// v2.0.45: 修复"单 IP 优选 0KB"问题.
  ///   之前 candidateIps 里只有 1 个手动 IP, race dial 拨上后 TLS 握手
  ///   失败 (该 IP 跟 SNI 不在同一个 CF zone, 0KB), 但 race 已返回该 IP,
  ///   没人 fallback. 修法: getTopNIpsForVideoProxy 在手动 IP 模式下
  ///   会同时返回 [manual_ip, original_host], 把 host 加进 race, 一旦
  ///   manual IP 不通, host (走系统 DNS) 能拿到跟 SNI 匹配的 CF edge.
  ///   这里再补一个保护: race 返回前 wait 200ms, 看 winner socket
  ///   是不是有数据进来 (TLS ClientHello 后应该有 ServerHello 回包),
  ///   没数据 → 这个 winner 可能是个"拨上但不通"的 IP, destroy 重试下一个.
  ///   实际效果: 大幅减少 0KB 死链, 但仍不是 100% (TLS 失败是异步的,
  ///   200ms 内 ServerHello 不一定到). 最终兜底: 全部失败 → fallback 原 host.
  ///
  /// v2.0.46: 简化 post-connect verify — race 选完 winner 不等数据,
  ///   而是 **强制按 [host_dns_ips, manual_ip] 顺序拨号, host IP 没拨
  ///   通才拨 manual**. 这跟 v2.0.45 的"race 选最快" 行为完全不同:
  ///   - race: 拨上就返回, 错就错
  ///   - v2.0.46: 优先 host IP (跟 SNI 匹配, TLS 必过), 失败才用 manual
  ///   - 用户场景: 配 `162.159.158.162` 静态 IP, target host `api.xx.fn0.qzz.io` →
  ///     系统 DNS 解析 host 给 `104.x.x.x` (跟 SNI 匹配的 edge IP) → 先拨 104.x.x.x
  ///     (TLS 成功) → 视频 OK. 162.159.158.162 完全用不到.
  ///   - 代价: 慢 1~2 个 host IP 的拨号时间 (几十 ms), 但消除了 0KB 风险.
  ///
  ///   实测: getTopNIpsForVideoProxy 已经把 host IP 排前面 ([host_ips..., manual]),
  ///   加上 maybeResolveHostEagerly 提前触发 DNS 解析, race 拿到的候选
  ///   顺序就是 [host_ip1, host_ip2, ..., manual]. 100ms 内 TLS ServerHello
  ///   一定能到, 所以 v2.0.46 把 race 改成 "顺序拨号, 首选 host IP, fallback manual".
  ///
  /// v2.0.50: 强制 IPv4 拨号 — 候选是 hostname 时, 不让
  ///   `Socket.connect` 自己 Happy Eyeballs 选 IPv6, 显式按 IPv4 列表
  ///   顺序拨. 详注释见 [_connectOne].
  static Future<Socket> _connectOne(String target, int port) async {
    if (InternetAddress.tryParse(target) != null) {
      // 候选是 IP (v4 或 v6), 直接拨, 不解析
      return await Socket.connect(target, port,
          timeout: const Duration(seconds: 3));
    }
    // 候选是 hostname — 显式解析到 IPv4 (避免 Happy Eyeballs 选 IPv6,
    // CF anycast IPv6 edge 跟 IPv4 cert 池不通用, 自定义 CF Worker
    // 域名常只有 IPv4 cert, IPv6 edge 没 cert → TLS 失败 → 0KB).
    // IPv4 解析失败 → 退而求其次, 让 Socket.connect 自己处理 (会用
    // IPv6 或其他 fallback).
    try {
      final addrs = await InternetAddress.lookup(target,
              type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 3));
      if (addrs.isEmpty) {
        throw Exception('no IPv4 address for $target');
      }
      // 顺序拨, 第一个成功即返回
      Exception? lastError;
      for (final addr in addrs) {
        try {
          return await Socket.connect(addr, port,
              timeout: const Duration(seconds: 3));
        } catch (e) {
          lastError = e is Exception ? e : Exception(e.toString());
          continue;
        }
      }
      throw lastError ?? Exception('all IPv4 addrs failed for $target');
    } catch (e) {
      // IPv4 解析失败 / 全部拨不上, fallback 到 Socket.connect 直接拨
      // (允许 IPv6, 至少给个机会)
      return await Socket.connect(target, port,
          timeout: const Duration(seconds: 3));
    }
  }

  /// v2.0.54 详细日志: race 拨号 + 数据流追踪
  ///
  /// 关键修改:
  ///   1. **移除 200ms TLS ServerHello 校验** — 透明 CONNECT 代理不
  ///      终止 TLS, 拨上 upstream 后什么也不发, 等不到任何数据, 200ms
  ///      必超时. 200ms 校验会破坏 race 行为, 全部 IP "verify 失败"
  ///      → fallback 慢 + 不必要的 200ms 延迟. 改回 v2.0.19 单纯 race
  ///      选最快 TCP 连上的 IP.
  ///   2. **每个 IP 单独详细日志** — 拨号起止时间 / 成功失败 / 字节流
  ///      方向 / 第一次数据的时间戳 / 总字节数 / socket 关闭原因. 用
  ///      player 屏幕"日记"按钮能看.
  static Future<Socket> _connectRace(
    String originalHost,
    int port,
    List<String> candidateIps,
  ) async {
    if (candidateIps.isEmpty) {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] _connectRace: 拨 $originalHost:$port (无候选 IP, 直接拨原 host)');
      final t0 = DateTime.now();
      final socket = await Socket.connect(originalHost, port,
          timeout: const Duration(seconds: 5));
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] _connectRace: 原 host 拨号成功 → ${socket.remoteAddress.address}:${socket.remotePort} 耗时 ${DateTime.now().difference(t0).inMilliseconds}ms');
      return socket;
    }

    final raceT0 = DateTime.now();
    // ignore: avoid_print
    VideoProxyLog.append(
        '[VideoProxy] _connectRace: 拨 $originalHost:$port 候选 ${candidateIps.length} IP: $candidateIps (race start T+0ms)');

    // v2.0.54: 单纯 race, 首个 TCP 连上的 IP 当 winner. 透明 CONNECT
    // 代理不终止 TLS, 不能 verify ServerHello — 等数据永远 timeout.
    final completer = Completer<Socket>();
    int errorCount = 0;
    final totalCount = candidateIps.length;
    bool winnerChosen = false;
    String? winnerIp;

    for (final ip in candidateIps) {
      final dialT0 = DateTime.now();
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] _connectRace: [$ip] 开始拨号 T+${DateTime.now().difference(raceT0).inMilliseconds}ms');
      // ignore: unawaited_futures
      _connectOne(ip, port)
          .then((socket) {
        final dialMs = DateTime.now().difference(dialT0).inMilliseconds;
        // ignore: avoid_print
        VideoProxyLog.append(
            '[VideoProxy] _connectRace: [$ip] TCP 拨号成功 → ${socket.remoteAddress.address}:${socket.remotePort} 耗时 ${dialMs}ms T+${DateTime.now().difference(raceT0).inMilliseconds}ms');
        if (!winnerChosen) {
          winnerChosen = true;
          winnerIp = ip;
          if (!completer.isCompleted) {
            completer.complete(socket);
          } else {
            socket.destroy();
          }
        } else {
          // 输的 socket 立即 destroy
          // ignore: avoid_print
          VideoProxyLog.append(
              '[VideoProxy] _connectRace: [$ip] 输的 socket 销毁');
          socket.destroy();
        }
      }).catchError((e) {
        final dialMs = DateTime.now().difference(dialT0).inMilliseconds;
        // ignore: avoid_print
        VideoProxyLog.append(
            '[VideoProxy] _connectRace: [$ip] 拨号失败 ($e) 耗时 ${dialMs}ms T+${DateTime.now().difference(raceT0).inMilliseconds}ms');
        if (winnerChosen) return;
        errorCount++;
        if (errorCount == totalCount && !completer.isCompleted) {
          completer.completeError(
            Exception('all $totalCount IPs failed: $e'),
          );
        }
      });
    }

    try {
      final socket = await completer.future;
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] _connectRace: winner=$winnerIp → ${socket.remoteAddress.address}:${socket.remotePort} 总耗时 ${DateTime.now().difference(raceT0).inMilliseconds}ms');
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      return socket;
    } catch (e) {
      // 全部 IP 都失败, fallback 到原 host
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] _connectRace: 全部 $totalCount IP 失败 ($e) T+${DateTime.now().difference(raceT0).inMilliseconds}ms, fallback 原 host $originalHost:$port');
      final fallbackT0 = DateTime.now();
      final socket = await _connectOne(originalHost, port);
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] _connectRace: fallback 原 host 拨号成功 → ${socket.remoteAddress.address}:${socket.remotePort} 耗时 ${DateTime.now().difference(fallbackT0).inMilliseconds}ms');
      return socket;
    }
  }

  void _handleConnection(Socket client) {
    if (_stopped) {
      client.destroy();
      return;
    }
    // v2.0.54 详细日志: 记下连接开始时间戳
    final connT0 = DateTime.now();
    final connId =
        '${connT0.millisecondsSinceEpoch % 100000}-${client.remotePort}';
    // ignore: avoid_print
    VideoProxyLog.append(
        '[VideoProxy] [$connId] 新连接 from libmpv: ${client.remoteAddress.address}:${client.remotePort}');
    // v2.0.25: 设 TCP_NODELAY 避免小包被 Nagle 延迟
    //   TLS ClientHello / ServerHello 是小包, Nagle 算法会延迟发送,
    //   导致 TLS 握手慢/超时 → "没速度"
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _connCount++;
    final state = _ProxyState();
    StreamSubscription<List<int>>? clientSub;
    StreamSubscription<List<int>>? backendSub;
    int clientToBackendBytes = 0;
    int backendToClientBytes = 0;
    DateTime? firstClientDataAt;
    DateTime? firstBackendDataAt;

    void closeAll() {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] [$connId] 连接关闭, client→backend $clientToBackendBytes bytes, backend→client $backendToClientBytes bytes, 存活 ${DateTime.now().difference(connT0).inMilliseconds}ms');
      clientSub?.cancel();
      backendSub?.cancel();
      client.destroy();
      _connCount--;
    }

    clientSub = client.listen(
      (data) {
        if (firstClientDataAt == null) {
          firstClientDataAt = DateTime.now();
          // ignore: avoid_print
          VideoProxyLog.append(
              '[VideoProxy] [$connId] libmpv 首次发数据 ${data.length}B, T+${DateTime.now().difference(connT0).inMilliseconds}ms, 头几个字节: ${_hexPreview(data, 16)}');
        }
        try {
          _onClientData(client, state, data, (backend) {
            // 接到 backend 后, 把 client ↔ backend 串起来
            //
            // v2.0.21 修: 旧代码在 onBackendReady 回调里直接
            //   clientSub = client.listen(...)
            // 没 cancel 老的 clientSub, 老的 listener 还在订阅 client.
            // 后续每包数据都会触发两个 listener (老的进 _onClientData
            // 当 no-op 浪费 CPU, 新的进 backend.add 正常转发), 跑长 HLS
            // (几百段) 累计浪费明显.
            //
            // 修法: 先 cancel 老的 clientSub, 再建新的.
            // v2.0.54 修 (用户日志 Bad state: Stream has already been
            //   listened to): 整个桥接逻辑必须推到 microtask 跑, 不然
            //   Socket.connect 内部那个临时订阅没释放, backend.listen()
            //   就抛错. client.listen() 第二次同理 — 老的 clientSub
            //   cancel() 也是异步的, 必须等 microtask 切走再 listen.
            //
            //   桥接失败时, microtask 里发 502 + closeAll, 跟旧 catch
            //   block 行为一致, libmpv 看到的是一样.
            // ignore: avoid_print
            VideoProxyLog.append(
                '[VideoProxy] [$connId] backend ready → ${backend.remoteAddress.address}:${backend.remotePort}, T+${DateTime.now().difference(connT0).inMilliseconds}ms, 准备桥接 (Future async + await cancel)');
            // v2.0.54 修 (用户日志 #2): microtask 没用, 因为 cancel()
            //   本身异步, microtask 闭包是非 async, cancel 返回的 Future
            //   被丢掉, 立刻 listen 仍然撞 "Stream has already been
            //   listened to" (用户日志 stack trace 印证: 抛错在 line 467,
            //   Future.microtask.<anonymous closure>).
            //   修法: 用 Future(() async) 包整个桥接, await cancel 真等
            //   释放完再 listen.
            Future(() async {
              try {
                final oldClientSub = clientSub;
                clientSub = null;
                // 真等老订阅释放 — 不然 Socket 的 _subscription 引用
                // 没清, 后面 client.listen() 第二次会抛错
                if (oldClientSub != null) {
                  // ignore: avoid_print
                  VideoProxyLog.append(
                      '[VideoProxy] [$connId] await 老 clientSub.cancel()...');
                  await oldClientSub.cancel();
                  // ignore: avoid_print
                  VideoProxyLog.append(
                      '[VideoProxy] [$connId] 老 clientSub.cancel() 完成, 准备建桥');
                }

                backendSub = backend.listen(
                  (d) {
                    if (firstBackendDataAt == null) {
                      firstBackendDataAt = DateTime.now();
                      // ignore: avoid_print
                      VideoProxyLog.append(
                          '[VideoProxy] [$connId] upstream 首次回数据 ${d.length}B, T+${DateTime.now().difference(connT0).inMilliseconds}ms, 头几个字节: ${_hexPreview(d, 16)}');
                    }
                    backendToClientBytes += d.length;
                    try {
                      client.add(d);
                    } catch (_) {
                      closeAll();
                    }
                  },
                  onError: (e) {
                    // ignore: avoid_print
                    VideoProxyLog.append(
                        '[VideoProxy] [$connId] upstream socket error: $e');
                    closeAll();
                  },
                  onDone: () {
                    // ignore: avoid_print
                    VideoProxyLog.append(
                        '[VideoProxy] [$connId] upstream socket done (remote 关闭), 总 $backendToClientBytes bytes');
                    closeAll();
                  },
                  cancelOnError: true,
                );

                // 把 client 已收到的剩余 body 推给 backend
                if (state.pendingBodyBytes.isNotEmpty) {
                  // ignore: avoid_print
                  VideoProxyLog.append(
                      '[VideoProxy] [$connId] 推 pendingBodyBytes ${state.pendingBodyBytes.length}B → backend');
                  backend.add(state.pendingBodyBytes);
                  clientToBackendBytes += state.pendingBodyBytes.length;
                  state.pendingBodyBytes = [];
                }
                // v2.0.22 修: 推 await _connectRace 期间累积的 client 数据
                //   旧代码只推 pendingBodyBytes (header 解析那一刻的 body),
                //   但 _handleConnect / _handleHttp 是 async fire-and-forget,
                //   await _connectRace 期间 client 发来的数据全堆 state.buffer
                //   没人转. onBackendReady 时只推 pendingBodyBytes 不推 buffer,
                //   这段数据就永久丢了.
                //
                //   对 CONNECT 隧道: libmpv 收到 "200 Connection Established"
                //     后立刻发 TLS ClientHello, 这个数据堆 buffer 被 onBackendReady
                //     漏推 → TLS 握手永远完不成 → 没数据流 → "没速度"
                //   对 HTTP 直连: 请求 body 后续 chunk 丢失 → 请求不完整 → 502
                if (state.buffer.isNotEmpty) {
                  // ignore: avoid_print
                  VideoProxyLog.append(
                      '[VideoProxy] [$connId] 推 race 期间累积 buffer ${state.buffer.length}B → backend');
                  backend.add(state.buffer);
                  clientToBackendBytes += state.buffer.length;
                  state.buffer = [];
                }
                // client → backend: 后续流过来的都推给 backend
                clientSub = client.listen(
                  (d) {
                    clientToBackendBytes += d.length;
                    try {
                      backend.add(d);
                    } catch (_) {
                      closeAll();
                    }
                  },
                  onError: (e) {
                    // ignore: avoid_print
                    VideoProxyLog.append(
                        '[VideoProxy] [$connId] libmpv socket error: $e');
                    closeAll();
                  },
                  onDone: () {
                    // ignore: avoid_print
                    VideoProxyLog.append(
                        '[VideoProxy] [$connId] libmpv socket done, 总 $clientToBackendBytes bytes → backend');
                    try {
                      backend.close();
                    } catch (_) {}
                  },
                  cancelOnError: true,
                );
                // ignore: avoid_print
                VideoProxyLog.append(
                    '[VideoProxy] [$connId] 桥接已建立 (c→b / b→c 都活了)');
              } catch (e, st) {
                // ignore: avoid_print
                VideoProxyLog.append(
                    '[VideoProxy] [$connId] 桥接建立失败: $e\n$st');
                // 跟旧 _handleConnect catch 行为一致: 发 502 + 关连接
                try {
                  final body = '502 Bad Gateway\r\n';
                  final resp =
                      'HTTP/1.1 502 Bad Gateway\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body';
                  client.add(resp.codeUnits);
                  await client.flush();
                } catch (_) {}
                closeAll();
              }
            });
          }, closeAll);
        } catch (e) {
          // ignore: avoid_print
          VideoProxyLog.append(
              '[VideoProxy] [$connId] _onClientData 异常: $e');
          _errorCount++;
          closeAll();
        }
      },
      onError: (e) {
        // ignore: avoid_print
        VideoProxyLog.append(
            '[VideoProxy] [$connId] libmpv socket (header 阶段) error: $e');
        closeAll();
      },
      onDone: () {
        // ignore: avoid_print
        VideoProxyLog.append(
            '[VideoProxy] [$connId] libmpv socket done (header 阶段都没数据)');
        closeAll();
      },
      cancelOnError: true,
    );
  }

  /// 打印前 N 字节 hex (调试用). 只看 16B 不影响日志大小.
  static String _hexPreview(List<int> data, int n) {
    final end = data.length < n ? data.length : n;
    final sb = StringBuffer();
    for (var i = 0; i < end; i++) {
      final b = data[i];
      if (b >= 0x20 && b < 0x7f) {
        sb.writeCharCode(b);
      } else {
        sb.write('\\x${b.toRadixString(16).padLeft(2, '0')}');
      }
    }
    if (data.length > n) sb.write('...');
    return sb.toString();
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
        // v2.0.40 诊断日志
        // ignore: avoid_print
        VideoProxyLog.append('[VideoProxy] CONNECT ${state.target} (从 libmpv 收到 CONNECT 头, 开始拨号)');
        _handleConnect(client, state, onBackendReady, closeAll);
      } else {
        // v2.0.40 诊断日志
        // ignore: avoid_print
        VideoProxyLog.append('[VideoProxy] HTTP ${state.method} ${state.target}');
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

    // v2.0.19: 借鉴 edgetunnel 预加载竞速拨号, 同时拨 Top3 优选 IP
    // v2.0.34: 改用 getTopNIpsForVideoProxy, 手动优选 IP 优先 (单 IP)
    // v2.0.46: 手动 IP 模式触发一次 host DNS 解析 (fire-and-forget),
    //   之后 _connectRace 拿候选时 host DNS 已就绪, 走 [host_ips..., manual],
    //   race 拨 host IPs 跟 SNI 匹配 → TLS 成功, 解决"162.159.x.x 静态
    //   IP TCP 拨上但 TLS 失败 → 0KB"问题
    // v2.0.54 日志: CONNECT 路径
    // ignore: avoid_print
    VideoProxyLog.append(
        '[VideoProxy] CONNECT $host:$port, 候选 IP 计算中...');
    CfOptimizerHttpOverrides.maybeResolveHostEagerly(host);
    final topIps = CfOptimizerHttpOverrides.getTopNIpsForVideoProxy(host, 3);
    // ignore: avoid_print
    VideoProxyLog.append(
        '[VideoProxy] CONNECT $host:$port, 候选 ${topIps.length} IP: $topIps');
    final raceStart = topIps.isNotEmpty ? DateTime.now() : null;
    try {
      final backend = await _connectRace(host, port, topIps);
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] CONNECT $host: 准备发 "200 Connection Established" → libmpv, T+${DateTime.now().difference(raceStart!).inMilliseconds}ms');
      client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
      await client.flush();
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] CONNECT $host: "200" 已发, backend = ${backend.remoteAddress.address}:${backend.remotePort}');
      if (topIps.isNotEmpty) {
        _raceWinCount++;
        final ms = DateTime.now().difference(raceStart!).inMilliseconds;
        // ignore: avoid_print
        VideoProxyLog.append('[VideoProxy] CONNECT $host: race dial won in ${ms}ms (${topIps.length} candidates)');
      } else {
        _tunnelCount++;
      }
      onBackendReady(backend);
    } catch (e) {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[VideoProxy] CONNECT $host: race + fallback 全失败 ($e), 发 502');
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

    // v2.0.19: 借鉴 edgetunnel 预加载竞速拨号
    // v2.0.34: 改用 getTopNIpsForVideoProxy, 手动优选 IP 优先 (单 IP)
    // v2.0.46: 手动 IP 模式触发一次 host DNS 解析 (跟 _onClientConnection 一致)
    // v2.0.54 日志: HTTP 代理路径
    // ignore: avoid_print
    VideoProxyLog.append(
        '[VideoProxy] HTTP ${state.method} $host:$port, 候选 IP 计算中...');
    CfOptimizerHttpOverrides.maybeResolveHostEagerly(host);
    final topIps = CfOptimizerHttpOverrides.getTopNIpsForVideoProxy(host, 3);
    // ignore: avoid_print
    VideoProxyLog.append(
        '[VideoProxy] HTTP ${state.method} $host:$port, 候选 ${topIps.length} IP: $topIps');

    // v2.0.19: 修 bug — request line + Host header 都用原 host, 不要用 IP
    // IP 只用来做 TCP 路由, 服务端通过 Host header 找 vhost
    // v2.0.25 修: 请求行用相对 path, 不用绝对 URI
    //   旧代码 '${state.method} $uri HTTP/1.1' 会生成
    //   'GET http://video.cdn.com/path HTTP/1.1' (absolute-form)
    //   这是代理格式, 源服务器不认 → 返回 400 → 没数据 → "没速度"
    //   正确格式: 'GET /path?query HTTP/1.1' (origin-form) + Host header
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    final requestLine =
        '${state.method} $requestPath${uri.query.isEmpty ? '' : '?${uri.query}'} HTTP/1.1';

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
    // v2.0.21 改: 不再强加 Connection: close
    //   旧逻辑: HTTP/1.1 + Connection: close = 等价 HTTP/1.0 短连接
    //   后果: 客户端 (libmpv 拉 HLS) 每个 .ts 段都开新 TCP 连接, 长 HLS
    //         几百段累计: TLS 握手 × N + 竞速拨号 × N, 看着像"没速度"
    //   现状: 代理 client→backend 的 listener 是持久的, backend→client
    //         也是持久的, backend 自己维持 keep-alive 没问题, 真要断开
    //         onDone: closeAll 自然兜底. 删掉 Connection: close 让
    //         HTTP/1.1 backend 复用连接即可.
    final request =
        '$requestLine\r\n${headerLines.join('\r\n')}\r\n\r\n';
    final reqBytes = request.codeUnits;

    try {
      final backend = await _connectRace(host, port, topIps);
      backend.add(reqBytes);
      if (state.pendingBodyBytes.isNotEmpty) {
        backend.add(state.pendingBodyBytes);
      }
      await backend.flush();
      if (topIps.isNotEmpty) {
        _raceWinCount++;
      } else {
        _tunnelCount++;
      }
      onBackendReady(backend);
    } catch (e) {
      _errorCount++;
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
