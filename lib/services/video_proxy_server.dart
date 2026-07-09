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

  static Future<Socket> _connectRace(
    String originalHost,
    int port,
    List<String> candidateIps,
  ) async {
    if (candidateIps.isEmpty) {
      // 没候选 IP, 直接连原 host
      return await Socket.connect(originalHost, port,
          timeout: const Duration(seconds: 5));
    }

    // v2.0.40 诊断日志
    if (candidateIps.isNotEmpty) {
      // ignore: avoid_print
      VideoProxyLog.append('[VideoProxy] _connectRace: 拨 $originalHost:$port 候选 ${candidateIps.length} IP: $candidateIps');
    } else {
      // ignore: avoid_print
      VideoProxyLog.append('[VideoProxy] _connectRace: 拨 $originalHost:$port (无候选 IP, 走原 host)');
    }

    // v2.0.53: race 并发 + 200ms TLS ServerHello 校验.
    //   v2.0.19 单纯 race 选最快 — 快但可能拨上 cert 错的 IP → 0KB.
    //   v2.0.46/48 改顺序拨号 host 永远第一 — 稳但优选 IP 永远拨不到
    //   (用户场景: 配 50ms 的 优选 IP, host DNS 是 286ms, 顺序拨号
    //   永远先拨 host, manual 完全用不到, 优选白设了).
    //   折中: 多个 IP race 并发拨号, 拨上的 socket 立即等 200ms 看有
    //   没有数据进来 (libmpv 收到 200 后立刻发 TLS ClientHello, 那边
    //   就该回 ServerHello). 第一个拿到数据的 IP 当 winner, 其余 destroy.
    //   200ms 内没数据 → "拨上但不通" (cert 错的 edge), destroy 它,
    //   race 选下一个. 这样优选 IP 能赢 (快), 万一没 cert 也兜得住.
    if (candidateIps.length > 1) {
      return await _raceWithTlsVerify(originalHost, port, candidateIps);
    }

    // 1 个候选: 用 v2.0.19 race 逻辑 (直接拨, 失败 fallback)
    final completer = Completer<Socket>();
    int errorCount = 0;
    final totalCount = candidateIps.length;
    bool winnerChosen = false;

    for (final ip in candidateIps) {
      // v2.0.50: 用 _connectOne, hostname 强制 IPv4
      // ignore: unawaited_futures
      _connectOne(ip, port)
          .then((socket) {
        if (!winnerChosen) {
          winnerChosen = true;
          if (!completer.isCompleted) {
            completer.complete(socket);
          } else {
            socket.destroy();
          }
        } else {
          // v2.0.21: 输的 socket 立即 destroy, 不留到 OS 超时
          socket.destroy();
        }
      }).catchError((e) {
        // v2.0.21: winner 已选就忽略, 别把 errorCount 累上去
        // (旧代码这里会被输的 catchError 干扰, completer 已完成
        // completeError 是 no-op 但语义上错乱, 不利于调试)
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
      // v2.0.25: backend 也设 TCP_NODELAY
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      // v2.0.40 诊断日志: 哪个 IP 真拨上
      // ignore: avoid_print
      VideoProxyLog.append('[VideoProxy] _connectRace: 拨号成功 → ${socket.remoteAddress.address}:${socket.remotePort}');
      return socket;
    } catch (e) {
      // 全部 IP 都失败, fallback 到原 host
      // ignore: avoid_print
      VideoProxyLog.append('[VideoProxy] _connectRace: 全部 ${candidateIps.length} IP 失败 ($e), fallback 原 host $originalHost:$port');
      final socket = await _connectOne(originalHost, port);
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      // ignore: avoid_print
      VideoProxyLog.append('[VideoProxy] _connectRace: fallback 原 host 拨号成功 → ${socket.remoteAddress.address}:${socket.remotePort}');
      return socket;
    }
  }

  /// v2.0.53: race 并发拨号 + 200ms TLS ServerHello 校验.
  ///   每个 IP 拨上后立即等 200ms 拿数据, 第一个拿到数据的当 winner.
  ///   没数据的当 "拨上但不通" (cert 错的 edge), destroy, 让 race 选下一个.
  ///   全部 IP 都失败 → fallback 原 host.
  static Future<Socket> _raceWithTlsVerify(
    String originalHost,
    int port,
    List<String> candidateIps,
  ) async {
    if (candidateIps.isEmpty) {
      return await _connectOne(originalHost, port);
    }

    final completer = Completer<Socket>();
    final connectedSockets = <String, Socket>{};
    final failedIps = <String>{};
    int dialErrorCount = 0;
    bool resolved = false;
    String? winnerIp;

    void tryFallback() {
      if (resolved) return;
      // 还在 dial 中就不 fallback
      if (dialErrorCount + failedIps.length + connectedSockets.length <
          candidateIps.length) {
        return;
      }
      // 全部 IP 都失败了
      resolved = true;
      _connectOne(originalHost, port).then((socket) {
        try {
          socket.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        // ignore: avoid_print
        VideoProxyLog.append(
            '[VideoProxy] _raceWithTlsVerify: 全部 ${candidateIps.length} IP verify 失败, fallback 原 host $originalHost:$port 拨号成功');
        completer.complete(socket);
      }).catchError((e) {
        completer.completeError(e);
      });
    }

    for (final ip in candidateIps) {
      _connectOne(ip, port).then((socket) async {
        if (resolved) {
          socket.destroy();
          return;
        }
        connectedSockets[ip] = socket;

        // 立即等 200ms 拿数据 (TLS ServerHello)
        final hasData = await _waitForSocketData(
            socket, const Duration(milliseconds: 200));
        if (resolved) {
          if (connectedSockets[ip] == socket && ip != winnerIp) {
            socket.destroy();
            connectedSockets.remove(ip);
          }
          return;
        }
        if (hasData) {
          // 拿到数据了! 这个 IP 通
          resolved = true;
          winnerIp = ip;
          // ignore: avoid_print
          VideoProxyLog.append(
              '[VideoProxy] _raceWithTlsVerify: 拨号 + TLS 200ms 内成功 → ${socket.remoteAddress.address}:${socket.remotePort} (winner: $ip)');
          // destroy 其他所有 IP
          for (final entry in connectedSockets.entries) {
            if (entry.key != ip) {
              entry.value.destroy();
            }
          }
          connectedSockets.clear();
          try {
            socket.setOption(SocketOption.tcpNoDelay, true);
          } catch (_) {}
          completer.complete(socket);
        } else {
          // 200ms 内没数据, 这个 IP 拨上但不通 (cert 错的 edge)
          // ignore: avoid_print
          VideoProxyLog.append(
              '[VideoProxy] _raceWithTlsVerify: $ip 200ms 内没数据 (拨上但 TLS 不通), destroy, 让其他 IP 接');
          socket.destroy();
          connectedSockets.remove(ip);
          failedIps.add(ip);
          tryFallback();
        }
      }).catchError((e) {
        if (resolved) return;
        dialErrorCount++;
        // ignore: avoid_print
        VideoProxyLog.append(
            '[VideoProxy] _raceWithTlsVerify: 拨 $ip 直接失败 ($e)');
        tryFallback();
      });
    }

    return await completer.future;
  }

  /// 等 socket 收到数据. 有数据返 true, 超时或断开返 false.
  static Future<bool> _waitForSocketData(Socket socket, Duration timeout) async {
    if (socket.isClosed) return false;
    final completer = Completer<bool>();
    late StreamSubscription sub;
    Timer? timer;

    sub = socket.listen(
      (_) {
        if (!completer.isCompleted) {
          timer?.cancel();
          completer.complete(true);
        }
        sub.cancel();
      },
      onError: (_) {
        if (!completer.isCompleted) {
          timer?.cancel();
          completer.complete(false);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          timer?.cancel();
          completer.complete(false);
        }
      },
      cancelOnError: true,
    );

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        sub.cancel();
        completer.complete(false);
      }
    });

    return completer.future;
  }

  void _handleConnection(Socket client) {
    if (_stopped) {
      client.destroy();
      return;
    }
    // v2.0.40 诊断日志: 确认 libmpv 真 connect 到本地代理 (而不是绕过去直连)
    // v2.0.42: 走 VideoProxyLog 双写, 玩家屏幕"日记"按钮能看
    VideoProxyLog.append('[VideoProxy] 新连接 from libmpv: ${client.remoteAddress.address}:${client.remotePort}');
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
            //
            // v2.0.21 修: 旧代码在 onBackendReady 回调里直接
            //   clientSub = client.listen(...)
            // 没 cancel 老的 clientSub, 老的 listener 还在订阅 client.
            // 后续每包数据都会触发两个 listener (老的进 _onClientData
            // 当 no-op 浪费 CPU, 新的进 backend.add 正常转发), 跑长 HLS
            // (几百段) 累计浪费明显.
            //
            // 修法: 先 cancel 老的 clientSub, 再建新的.
            final oldClientSub = clientSub;
            clientSub = null;
            oldClientSub?.cancel();
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
            //
            //   这就是用户反馈"从 v2.0 开始没速度, 关掉 CF 加速就正常"的
            //   真根因 — 不是慢, 是 TLS 握手数据丢了整条流就死了.
            if (state.buffer.isNotEmpty) {
              backend.add(state.buffer);
              state.buffer = [];
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
    CfOptimizerHttpOverrides.maybeResolveHostEagerly(host);
    final topIps = CfOptimizerHttpOverrides.getTopNIpsForVideoProxy(host, 3);
    final raceStart = topIps.isNotEmpty ? DateTime.now() : null;
    try {
      final backend = await _connectRace(host, port, topIps);
      client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
      await client.flush();
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
    CfOptimizerHttpOverrides.maybeResolveHostEagerly(host);
    final topIps = CfOptimizerHttpOverrides.getTopNIpsForVideoProxy(host, 3);

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
