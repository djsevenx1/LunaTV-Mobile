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
//
// v2.0.57: 2 阶段拨号 (host race → manual fallback → 原 host fallback).
//   见 _connectRace 注释. 解决 "4 秒卡顿" bug: manual IP (cf.877774.xyz
//   类的 fast CF IP) TCP 拨上快但 TLS ServerHello 慢 (500ms+), 跟 host
//   IP 并发 race 时 manual 总是胜出 → HLS 段拉不完卡 4s. 修法: manual
//   不参与 race, 仅在 host IP 全失败时单独拨.

import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:luna_tv/services/cf_optimizer.dart' show CfOptimizerHttpOverrides;
import 'package:luna_tv/services/diary_service.dart';
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
    // v2.0.76: 守门改成 getVideoProxyEnabled() — 该开关现在是「视频代理」,
    //   关 = 视频不走代理, 直接原源; 开 = 视频走 VideoProxyServer.
    final videoProxyOn = await UserDataService.getVideoProxyEnabled();
    if (!videoProxyOn) return null;

    // 守门 2: 域名配了
    final domain = await UserDataService.getCfWorkerDomain();
    if (domain.isEmpty) return null;

    // v2.0.76: 「优选 IP 启用」开关 (v2.0.75 之前叫 "代理总开关") 决定视频流走不走优选 IP.
    //   这里只读状态打日志 + 算 effectiveIp, 不作守门 — 开关关也能启代理 (走 worker 系统 DNS).
    final preferIpEnabled = await UserDataService.getCfWorkerEnabled();
    final resolvedIp = CfOptimizerHttpOverrides.getResolvedManualIp();
    final effectiveIp = (preferIpEnabled && resolvedIp != null && resolvedIp.isNotEmpty)
        ? resolvedIp
        : null;

    // 全部满足, 启代理
    try {
      final s = VideoProxyServer._();
      await s._bind();
      return s;
    } catch (e, st) {
      // v2.0.39: 不再静默吞, 打印详细原因.
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
  ///
  /// v2.0.57 关键修复 — **manual IP 不再参与 race** (2 阶段拨号):
  ///   之前 v2.0.46/v2.0.48 把 candidateIps 排成 [host_ips..., manual],
  ///   但 _connectRace 仍是并发 race — 首个 TCP 拨上的胜出. 用户场景:
  ///   配 `141.101.115.52` 手动优选 IP (cf.877774.xyz 给的 fast CF IP),
  ///   host DNS 给 `104.x.x.x` (跟 SNI 匹配的 edge). race 同时拨:
  ///     - host IP 104.x.x.x: TCP 80ms 拨上, TLS ServerHello 0~5ms 到 (跟 SNI 匹配)
  ///     - manual IP 141.101.115.52: TCP 50ms 拨上, **TLS ServerHello 500ms+** 才到
  ///   manual TCP 拨上更快 → race 选 manual → 走通后 4 秒卡顿 (HLS segment
  ///   拉不完). 用户反馈: "可以播放了但是怎么所有视频只有 4s" + "关掉优选是正常的".
  ///
  ///   修法: 把 candidateIps 拆成 [host_ips, manual]:
  ///     - **Phase 1**: host IPs 之间并发 race, 首个拨上的胜出
  ///       (保留并发优势 — 多个 host IP 仍然比, 选最快)
  ///     - **Phase 2**: host IPs 全失败 → 单独拨 manual IP (不参与 race,
  ///       manual 仅是 host IP 死光后的 fallback)
  ///     - **Phase 3**: manual 也失败 → fallback 原 host (老路径兜底)
  ///   manual IP 不会再因 TCP 拨上快就胜出, 必须 host IPs 全死才轮
  ///   到. 代价: manual IP 场景下, video_proxy 比 v2.0.56 慢一个 manual
  ///   拨号时间 (~50ms), 换来 manual 永远不当 winner — 4s 卡顿消失.
  static Future<Socket> _connectRace(
    String originalHost,
    int port,
    List<String> candidateIps,
  ) async {
    if (candidateIps.isEmpty) {
      final t0 = DateTime.now();
      final socket = await Socket.connect(originalHost, port,
          timeout: const Duration(seconds: 5));
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      return socket;
    }

    final raceT0 = DateTime.now();
    // v2.0.57: 分类候选 IP — 哪些是 "host IP" (跟 SNI 匹配, 跟手动优选
    // IP 区分), 哪个是 "manual IP" (用户配的, 可能跟 SNI 不匹配).
    // 分类依据: getResolvedManualIp() 返的就是用户当前配的 manual IP.
    final manualIp = CfOptimizerHttpOverrides.getResolvedManualIp();
    final hostIps = <String>[];
    String? manualCandidate;
    for (final ip in candidateIps) {
      if (manualIp != null && manualIp.isNotEmpty && ip == manualIp) {
        manualCandidate ??= ip;
      } else {
        hostIps.add(ip);
      }
    }
    // candidateIps 里没 manual IP (极端情况: 用户改了 manual 但 race
    // 候选是缓存的), 把 manual 也加进 phase 2
    if (manualCandidate == null &&
        manualIp != null &&
        manualIp.isNotEmpty &&
        !candidateIps.contains(manualIp)) {
      manualCandidate = manualIp;
    }

    // Phase 1: host IPs 并发 race (跟 SNI 匹配, TLS 必成功)
    if (hostIps.isNotEmpty) {
      try {
        return await _connectRaceGroup(
          hostIps,
          'host',
          originalHost,
          port,
          raceT0,
        );
      } catch (e) {
      }
    }

    // Phase 2: 单独拨 manual IP (host IPs 全死才用, manual 不参与 race)
    if (manualCandidate != null) {
      final dialT0 = DateTime.now();
      try {
        final socket = await _connectOne(manualCandidate, port);
        try {
          socket.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        return socket;
      } catch (e) {
      }
    }

    // Phase 3: 全失败 → fallback 原 host (老路径兜底, 系统 DNS 解析)
    final fallbackT0 = DateTime.now();
    final socket = await _connectOne(originalHost, port);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    return socket;
  }

  /// v2.0.57: 单组 IP 并发 race, 首个 TCP 拨上的胜出. 输的 destroy.
  ///
  /// 跟之前 v2.0.46+ 的 race 实现几乎一样, 拆出来是因为现在分阶段:
  /// host IPs 一组 (race), manual IP 一组 (单拨). 这个方法负责一组
  /// 内的并发竞争.
  static Future<Socket> _connectRaceGroup(
    List<String> ips,
    String groupName,
    String originalHost,
    int port,
    DateTime raceT0,
  ) async {
    final completer = Completer<Socket>();
    int errorCount = 0;
    final totalCount = ips.length;
    bool winnerChosen = false;
    String? winnerIp;

    for (final ip in ips) {
      final dialT0 = DateTime.now();
      // ignore: unawaited_futures
      _connectOne(ip, port).then((socket) {
        final dialMs = DateTime.now().difference(dialT0).inMilliseconds;
        if (!winnerChosen) {
          winnerChosen = true;
          winnerIp = ip;
          if (!completer.isCompleted) {
            completer.complete(socket);
          } else {
            socket.destroy();
          }
        } else {
          socket.destroy();
        }
      }).catchError((e) {
        final dialMs = DateTime.now().difference(dialT0).inMilliseconds;
        if (winnerChosen) return;
        errorCount++;
        if (errorCount == totalCount && !completer.isCompleted) {
          completer.completeError(
            Exception('all $totalCount IPs in group $groupName failed: $e'),
          );
        }
      });
    }

    final socket = await completer.future;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    return socket;
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
    // v2.0.25: 设 TCP_NODELAY 避免小包被 Nagle 延迟
    //   TLS ClientHello / ServerHello 是小包, Nagle 算法会延迟发送,
    //   导致 TLS 握手慢/超时 → "没速度"
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _connCount++;
    final state = _ProxyState();
    // v2.0.56: clientSub 是 final (整个连接生命周期只 listen 1 次, 不取消
    //   不重建). 用 backendReady flag 切换 listener 行为, 避开 Socket
    //   single-subscription 不能 listen 第二次的坑.
    late final StreamSubscription<List<int>> clientSub;
    StreamSubscription<List<int>>? backendSub;
    int clientToBackendBytes = 0;
    int backendToClientBytes = 0;
    DateTime? firstClientDataAt;
    DateTime? firstBackendDataAt;
    // v2.0.61: 标记 client 是否已关闭, 30s 超时兜底用 (StreamSubscription
    //   没有 isCanceled getter, 用局部 bool 替代)
    bool clientClosed = false;
    Socket? backend;
    bool backendReady = false;
    // v2.0.63: backend 关闭后置 false, 阻止 Phase 2 继续往已关的 backend 写数据
    //   (写已关的 socket 会 Connection reset by peer)
    bool backendAlive = false;

    void closeAll({bool graceful = false}) {
      clientClosed = true;
      final aliveMs = DateTime.now().difference(connT0).inMilliseconds;
      // v2.0.58: 标记可疑短响应 — backend 回了数据但很少 (<2KB) 且连接活过
      //   500ms, 通常是 502/错误页/截断的段. 这是 "优选 IP 4s 时长" bug 的
      //   烟雾枪: m3u8 段拉不全 → libmpv 只拿到一小段 → 时长显示 4s.
      final short = backendReady &&
          backendToClientBytes > 0 &&
          backendToClientBytes < 2048 &&
          aliveMs > 500;
      try {
        clientSub.cancel();
      } catch (_) {}
      try {
        backendSub?.cancel();
      } catch (_) {}
      // v2.0.59: 修 m3u8 截断导致 4s 时长 bug.
      //   根因: backend (CF worker) 关闭后立刻 client.destroy() 会丢弃
      //   client socket 发送 buffer 里还没被 libmpv 读完的数据. m3u8 响应
      //   被 CF worker 用短连接发完就关, onDone 触发 closeAll() →
      //   client.destroy() → libmpv 拿到截断的 m3u8 → 只看到 1-2 段 → 4s.
      //   直连没这问题因为 libmpv 自己管 socket 生命周期.
      //   修法: backend 正常结束 (onDone) 用 graceful=true, 先 flush 确保
      //   buffer 数据发完再 close. 异常路径仍用 destroy() 立刻清.
      if (graceful) {
        try {
          // socket.flush() 返回 Future, 但这里不能 await (closeAll 不是 async).
          // 用 then 链: flush 完再 close. flush 期间数据在内核 buffer 里,
          // close() 不会丢 (Socket.close 是半关闭, 发完再关).
          client.flush().then((_) {
            try {
              client.close();
            } catch (_) {}
          }).catchError((_) {
            try {
              client.destroy();
            } catch (_) {}
          });
        } catch (_) {
          try {
            client.destroy();
          } catch (_) {}
        }
      } else {
        try {
          client.destroy();
        } catch (_) {}
      }
      _connCount--;
    }

    // v2.0.56: clientSub 是 client socket 的 SINGLE listener, 整个连接
    //   生命周期不变. 不取消不重建. 行为按 backendReady 切换:
    //   - Phase 1 (backendReady = false): 调 _onClientData 解析 header,
    //     期间累积的数据在 onBackendReady 里推到 backend.
    //   - Phase 2 (backendReady = true): 直接 backend.add(data) 转发.
    //   这是唯一不撞 Socket single-subscription 的写法.
    clientSub = client.listen(
      (data) {
        if (firstClientDataAt == null) {
          firstClientDataAt = DateTime.now();
        }
        // Phase 2: backend 已就绪, 直接转发
        if (backendReady && backend != null && backendAlive) {
          clientToBackendBytes += data.length;
          // v2.0.60: 详细记录 Phase 2 转发, 确认 libmpv 的 HTTP GET 请求
          //   是否被转发给 backend. 4s bug 怀疑 GET 请求没到 worker.
          try {
            backend!.add(data);
          } catch (_) {
            closeAll();
          }
          return;
        }
        // v2.0.63: backend 已关, 丢弃 libmpv 后续数据 (不能往已关的 socket 写)
        if (backendReady && !backendAlive) {
          return;
        }
        // Phase 1: 解析 header, 触发 race
        try {
          _onClientData(client, state, data, (b) {
            // onBackendReady callback — race 拨上后被调
            backend = b;
            // 推 race 期间累积的 client 数据到 backend
            if (state.pendingBodyBytes.isNotEmpty) {
              try {
                backend!.add(state.pendingBodyBytes);
              } catch (_) {}
              clientToBackendBytes += state.pendingBodyBytes.length;
              state.pendingBodyBytes = [];
            }
            // v2.0.22 修: 推 race 期间累积的 client 数据 (含 libmpv
            //   收到 200 后立刻发的 TLS ClientHello, 推不上 TLS 永远
            //   握不完 → 没速度)
            if (state.buffer.isNotEmpty) {
              try {
                backend!.add(state.buffer);
              } catch (_) {}
              clientToBackendBytes += state.buffer.length;
              state.buffer = [];
            }
            // backend 上 listen — 新 socket, 没 _subscription 冲突
            try {
              backendSub = backend!.listen(
                (d) {
                  if (firstBackendDataAt == null) {
                    firstBackendDataAt = DateTime.now();
                    // v2.0.58: HTTP (非 CONNECT) 路径能解析响应状态码 —
                    //   502/403/404 等会让 libmpv 拿到错误页, 表现为 "4s 时长".
                    //   CONNECT 是 TLS 隧道, 数据加密无法解析, 只看字节数.
                    String? statusHint;
                    if (state.method != null && state.method != 'CONNECT') {
                      statusHint = _parseHttpStatus(d);
                    }
                  }
                  backendToClientBytes += d.length;
                  try {
                    client.add(d);
                  } catch (_) {
                    closeAll();
                  }
                },
                onError: (e) {
                  backendAlive = false;
                  closeAll();
                },
                onDone: () {
                  // v2.0.61: 修 4s 时长 bug 真正根因 — backend 关闭时不能关 client!
                  //   之前 backend onDone 立刻 closeAll (v2.0.59 改 graceful 也不行),
                  //   client.close() 发 FIN 包, libmpv 读到 FIN 就停止读取,
                  //   client 内核 buffer 里还没读完的 sub-m3u8 数据就丢了.
                  //   sub-m3u8 274KB, libmpv 读得慢, backend 1.3s 传完就关,
                  //   libmpv 可能只读到开头几段 → duration 4s.
                  //   修法: backend onDone 只关 backend, 不关 client. client 等
                  //   libmpv 自己读完数据后关闭, client onDone 触发 closeAll.
                  //   风险: client 永不关闭会泄漏 socket. 加 30s 超时兜底.
                  backendAlive = false;
                  try {
                    backendSub?.cancel();
                  } catch (_) {}
                  try {
                    backend?.destroy();
                  } catch (_) {}
                  // 半关闭 client 写端: 告诉 libmpv 没有更多数据了, 但不强制关.
                  // flush 确保数据从 Dart 层刷到内核 buffer, close() 发 FIN.
                  // 但这次只 flush 不 close — 等 libmpv onDone.
                  try {
                    client.flush();
                  } catch (_) {}
                  // 30s 超时兜底: 如果 libmpv 30s 没关 client, 强制关 (防泄漏)
                  Future.delayed(const Duration(seconds: 30), () {
                    if (!clientClosed) {
                      closeAll();
                    }
                  });
                },
                cancelOnError: true,
              );
            } catch (e, st) {
              closeAll();
              return;
            }
            // 切到 Phase 2 — 后续 onData 直接转发
            backendReady = true;
            backendAlive = true;
          }, closeAll);
        } catch (e) {
          _errorCount++;
          closeAll();
        }
      },
      onError: (e) {
        closeAll();
      },
      onDone: () {
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

  // ===== v2.0.92: m3u8 ad 段预过滤 =====
  // v2.1.4: 加赌博站特征关键词 + 纯数字 host 识别 + 冷门 TLD 识别

  /// 跟 m3u8_service._looksLikeAdSegment 对齐, 测速/播放两种判断一致.
  /// v1.0.76 关键词 + v2.1.4 赌博站特征 (66588.co 截图实测漏判的 pattern).
  static const List<String> _adKeywords = [
    '/ad/',
    '/ads/',
    '/advert/',
    'doubleclick',
    'googlevideo',
    'imasdk',
    'adnxs',
    'admarvel',
    'pubmatic',
    // v2.1.4: 赌博站特征关键词 (URL-encoded 形式, 因 m3u8 里 segment
    //   URL 是 encoded)
    '%E8%91%A1%E4%BA%AC',     // 葡京
    '%E6%BE%B3%E9%97%A8',     // 澳门
    '%E5%87%AF%E5%8F%91',     // 凯发
    '%E9%93%AD%E6%B2%B3',     // 银河
    'bbin',
    'ag88',
    '365sb',
    '6668',
    '7899',
    '9999',
    '8800',
    '66588',                   // 66588.co 截图赌博站
  ];

  // v2.1.4: 赌博站常用冷门 TLD. 主片 CDN 不会用.
  static const List<String> _gamblingTlds = [
    '.top',
    '.cc',
    '.vip',
    '.cyou',
    '.xyz',
    '.click',
    '.loan',
    '.work',
    '.kim',
    '.rest',
    '.support',
  ];

  // v2.1.4: 4-5 位纯数字 host (66588/7899/8800/9999/6666 等). 主片 CDN
  //   不会用纯数字 host.
  static bool _isGamblingHost(String host) {
    if (host.isEmpty) return false;
    if (RegExp(r'^\d{4,5}$').hasMatch(host)) return true;
    for (final tld in _gamblingTlds) {
      if (host.endsWith(tld)) return true;
    }
    return false;
  }

  /// 段 URL 是不是明显广告. 跟 m3u8_service._looksLikeAdSegment 同规则.
  static bool _isAdUrl(String url, String baseHost) {
    final lower = url.toLowerCase();
    // 规则 1: 关键词
    for (final kw in _adKeywords) {
      if (lower.contains(kw)) return true;
    }
    // 规则 2 + 3: 跨域 + 赌博站 host
    String? segHost;
    try {
      segHost = Uri.parse(url).host.toLowerCase();
    } catch (_) {}
    if (segHost != null && segHost.isNotEmpty) {
      // 赌博站 host (v2.1.4): 即便跟 baseHost 同域, 也能识别
      if (_isGamblingHost(segHost)) return true;
      // 跨域 (跟 baseHost 二级域名不同)
      if (baseHost.isNotEmpty && segHost != baseHost) {
        final baseParts = baseHost.split('.');
        final segParts = segHost.split('.');
        if (baseParts.length >= 2 && segParts.length >= 2) {
          final baseApex = baseParts.sublist(baseParts.length - 2).join('.');
          final segApex = segParts.sublist(segParts.length - 2).join('.');
          if (baseApex != segApex) return true;
        } else {
          return true;
        }
      }
    } else if (baseHost.isNotEmpty) {
      // host 解析不出来, 当跨域处理
      return true;
    }
    return false;
  }

  /// 从 m3u8 内容所有段 URL 提取 base host.
  /// 策略: 统计所有 host 出现次数, **排除已知 ad host** (走关键词), 取最多.
  /// 平手时 (e.g. 主片 1 段 + ad 1 段): 用**最后出现**的 host — 视频源 ad
  /// 一般插在中间/开头, 最后一段几乎总是主片, 排除 ad host 后还平手就
  /// 用这个 tie-breaker.
  ///
  /// 为什么不用「最后一段」或「第一段」单选:
  ///   - 最后一段: ad 在结尾时 (罕见但存在) 最后一段就是 ad, 整个 m3u8 不动
  ///   - 第一段: ad 在开头时第一段就是 ad, 整个 m3u8 不动
  ///   - 多数 + 排除 ad + 最后出现 tie-breaker: 三种位置都覆盖
  static String? _detectBaseHostFromM3u8(List<String> lines) {
    final hosts = <String, int>{};
    final lastSeenIdx = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      try {
        final h = Uri.parse(line).host.toLowerCase();
        if (h.isNotEmpty) {
          hosts[h] = (hosts[h] ?? 0) + 1;
          lastSeenIdx[h] = i;
        }
      } catch (_) {}
    }
    if (hosts.isEmpty) return null;
    // 排除走关键词识别的 ad host (整个是 ad 服务, 不作 base)
    final nonAdHosts = hosts.entries.where((e) {
      return !_isAdUrl('http://${e.key}/placeholder', '');
    }).toList();
    final pool = nonAdHosts.isNotEmpty ? nonAdHosts : hosts.entries.toList();
    // 按 count desc, 平手时按 last-seen-idx desc (后出现优先)
    pool.sort((a, b) {
      final c = b.value.compareTo(a.value);
      if (c != 0) return c;
      return (lastSeenIdx[b.key] ?? 0).compareTo(lastSeenIdx[a.key] ?? 0);
    });
    return pool.first.key;
  }

  /// 清掉输出 m3u8 里变成孤儿的 EXT-X-DISCONTINUITY 标记.
  /// 删了 ad 段后, 前后两个 discontinuity 可能相邻 / 在头尾, 留着会触发
  /// libmpv 不必要的 decoder re-init (多次连续 discontinuity 等价连续重启解码).
  ///
  /// 规则:
  ///   - 头部的 discontinuity (前面没内容) 删
  ///   - 尾部的 discontinuity (后面没内容) 删
  ///   - 连续多个 discontinuity 合并成 1 个
  static List<String> _pruneOrphanDiscontinuities(List<String> lines) {
    // 找第一个有内容的行索引
    int firstContentIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trimRight();
      if (l.isEmpty || l == '#EXT-X-DISCONTINUITY') continue;
      firstContentIdx = i;
      break;
    }
    if (firstContentIdx < 0) return lines; // 全是 discontinuity, 不可能

    // 找最后一个有内容的行索引
    int lastContentIdx = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      final l = lines[i].trimRight();
      if (l.isEmpty || l == '#EXT-X-DISCONTINUITY') continue;
      lastContentIdx = i;
      break;
    }

    final out = <String>[];
    var lastWasDiscontinuity = false;
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final line = raw.trimRight();
      // 头部 / 尾部孤儿 discontinuity: 跳过
      if (line == '#EXT-X-DISCONTINUITY') {
        if (i < firstContentIdx) continue;
        if (i > lastContentIdx) continue;
        // 中间连续多个 discontinuity: 合并成 1 个
        if (lastWasDiscontinuity) continue;
        out.add(raw);
        lastWasDiscontinuity = true;
        continue;
      }
      // 空行不算 "内容", 不影响 lastWasDiscontinuity 状态
      if (line.isEmpty) {
        out.add(raw);
        continue;
      }
      out.add(raw);
      lastWasDiscontinuity = false;
    }
    return out;
  }

  /// v2.0.92: 从 m3u8 playlist 里删 ad 段 + 删孤儿 discontinuity.
  /// v2.1.4: 加日记记录删了多少段 + 列出 ad host (用户排查"卡住几秒
  ///   然后回到 N 分钟前").
  ///
  /// 配合 player_screen 的 runtime ad 跳:
  ///   - 这里: m3u8 重写时**物理删掉 ad 段**, libmpv 根本看不到 ad,
  ///     不再有"卡住几秒再跳过"
  ///   - runtime 跳: 兜底 — 万一跨域识别漏了, libmpv 还是加载了 ad 段,
  ///     duration 跳变触发 seek 回去, 至少不卡死死循环
  ///
  /// 边界: master playlist (含 #EXT-X-STREAM-INF) 不过滤, 子 m3u8 走 LOCAL
  /// 代理时被分别过滤.
  static String _stripAdsFromM3u8(String body, String workerDomain) {
    final lines = body.split('\n');
    final baseHost = _detectBaseHostFromM3u8(lines) ?? workerDomain;

    final out = <String>[];
    var removedAny = false;
    final removedHosts = <String, int>{}; // v2.1.4: ad host 统计
    var removedCount = 0;
    var i = 0;
    while (i < lines.length) {
      final raw = lines[i];
      final line = raw.trimRight();
      // 空行 / 主播放列表标记 / EXTM3U: 保留
      if (line.isEmpty ||
          line == '#EXTM3U' ||
          line.startsWith('#EXT-X-STREAM-INF')) {
        out.add(raw);
        i++;
        continue;
      }
      // #EXTINF: 它描述**下一个段 URL** 的时长. 看下一行是不是 ad, 是的话一起删.
      if (line.startsWith('#EXTINF:')) {
        if (i + 1 < lines.length) {
          final next = lines[i + 1].trimRight();
          if (_isAdUrl(next, baseHost)) {
            // v2.1.4: 记录被删的 ad host (debug 给 user 看, 排查广告源)
            _recordAdHost(removedHosts, next);
            // 删 #EXTINF + 段 URL
            i += 2;
            removedAny = true;
            removedCount++;
            continue;
          }
        }
        out.add(raw);
        i++;
        continue;
      }
      // 其他注释 (KEY, MAP, VERSION, TARGETDURATION, MEDIA-SEQUENCE, ENDLIST,
      //   CUE-OUT, CUE-IN, DISCONTINUITY 等): 保留
      if (line.startsWith('#')) {
        out.add(raw);
        i++;
        continue;
      }
      // 段 URL 行 (罕见 — 不带 #EXTINF 的孤立段, 兜底删)
      if (_isAdUrl(line, baseHost)) {
        _recordAdHost(removedHosts, line);
        removedAny = true;
        removedCount++;
        i++;
        continue;
      }
      out.add(raw);
      i++;
    }

    if (removedAny) {
      // v2.1.4: 日记记删了多少段 + 哪些 host, 排查"播放卡住几秒/回到 N 分钟前"
      try {
        final hostList = removedHosts.entries
            .map((e) => '${e.key}(${e.value})')
            .take(5)
            .join(', ');
        DiaryService.add(
            '[m3u8] stripped $removedCount ad segment(s), hosts=[$hostList], baseHost=$baseHost');
      } catch (_) {} // DiaryService import 失败也不影响主流程
      return _pruneOrphanDiscontinuities(out).join('\n');
    }
    return out.join('\n');
  }

  // v2.1.4: 记录被删的 ad host 统计
  static void _recordAdHost(Map<String, int> map, String url) {
    try {
      final h = Uri.parse(url).host.toLowerCase();
      if (h.isNotEmpty) {
        map[h] = (map[h] ?? 0) + 1;
      }
    } catch (_) {}
  }

  /// v2.0.58: 从 backend 首包解析 HTTP 响应状态行 (e.g. "HTTP/1.1 200 OK" → "200 OK").
  /// 用于诊断 "优选 IP 4s 时长" — 502/403/404 错误页会让 libmpv 拿到非视频内容.
  /// 返回 null = 不是 HTTP 响应 / 解析失败 (CONNECT 隧道加密数据也会返 null).
  static String? _parseHttpStatus(List<int> data) {
    if (data.length < 12) return null; // "HTTP/1.1 200" 至少 12 字节
    try {
      // 只取前 64 字节找 \r\n, 避免大包转字符串浪费
      final end = data.length < 64 ? data.length : 64;
      final head = String.fromCharCodes(data.sublist(0, end));
      if (!head.startsWith('HTTP/')) return null;
      final nl = head.indexOf('\r\n');
      final firstLine = nl >= 0 ? head.substring(0, nl) : head;
      // "HTTP/1.1 200 OK" → 取 "200 OK"
      final sp1 = firstLine.indexOf(' ');
      if (sp1 < 0) return null;
      return firstLine.substring(sp1 + 1).trim();
    } catch (_) {
      return null;
    }
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
        _handleConnect(client, state, onBackendReady, closeAll);
      } else if (state.target!.startsWith('/')) {
        // v2.0.65: 本地 HTTP 反向代理模式.
        //   libmpv 直接请求 http://127.0.0.1:PORT/m3u8?url=... (origin-form),
        //   代理自己 fetch https://worker/m3u8?url=... 返回内容.
        //   解决 libmpv 通过 --http-proxy CONNECT 隧道播放 HTTPS 失败的问题
        //   (libmpv 的 CONNECT 实现有 bug, ffmpeg 通过同一代理能播).
        _handleLocalHttp(client, state, closeAll);
      } else {
        // v2.0.40 诊断日志
        _handleHttp(client, state, onBackendReady, closeAll);
      }
    }
  }

  /// v2.0.65: 本地 HTTP 反向代理.
  ///
  /// libmpv 直接请求 `http://127.0.0.1:PORT/m3u8?url=XXX` (origin-form,
  /// target 以 / 开头). 代理自己用 HttpClient fetch
  /// `https://worker_domain/m3u8?url=XXX`, 把响应原样返回给 libmpv.
  ///
  /// 优势 (vs CONNECT 隧道):
  ///   - libmpv 不需要建 TLS 隧道, 避免 libmpv CONNECT bug
  ///   - HttpClient 走 CfOptimizerHttpOverrides, 自动用优选 IP 连 worker
  ///   - 响应是明文 HTTP, libmpv 直接解析, 不需要解密
  ///
  /// 劣势:
  ///   - m3u8 里的 .ts 链接是 https://worker/?url=..., libmpv 请求 .ts 时
  ///     会走 CONNECT (HTTPS), 又回到 libmpv 的 bug. 但 .ts 链接可以重写成
  ///     http://127.0.0.1:PORT/?url=... 让 libmpv 走本地代理.
  ///   → 代理在返回 m3u8 前, 把里面的 https://worker/ 链接全改成
  ///     http://127.0.0.1:PORT/
  Future<void> _handleLocalHttp(
    Socket client,
    _ProxyState state,
    void Function() closeAll,
  ) async {
    final target = state.target!; // e.g. /m3u8?url=XXX or /?url=XXX
    final workerDomain = await UserDataService.getCfWorkerDomain();
    if (workerDomain.isEmpty) {
      _sendHttpError(client, 502, 'worker domain not set', closeAll);
      return;
    }

    // v2.0.66: 不用 HttpClient (CfOptimizerHttpOverrides 会把 URI host 改成 IP,
    //   导致 TLS SNI = IP, CF edge 拒绝握手 → SSLV3_ALERT_HANDSHAKE_FAILURE).
    //   改用 SecureSocket.connect(preferIp, 443, host: workerDomain):
    //   - TCP 连优选 IP
    //   - TLS SNI = workerDomain (host 参数控制 SNI, 不是连接地址)
    //   - 手动发 HTTP/1.1 请求 + 流式读响应
    //
    // v2.0.76: 两开关语义重定义
    //   - 视频代理 (上面) = 控制视频是否走代理 (关 = 直连原源, tryStart 直接返 null)
    //   - 优选 IP 启用 (下面) = 控制所有资源 (含视频) 是否走优选 IP
    //   行为表 (视频):
    //     视频代理关 → tryStart 返 null → 直连视频源
    //     视频代理开 + 优选 IP 开关关 → 走 worker (系统 DNS)
    //     视频代理开 + 优选 IP 开关开 + IP 填了 → 走优选 IP + worker
    //     视频代理开 + 优选 IP 开关开 + IP 没填 → 走 worker (系统 DNS)
    final preferIpEnabled = await UserDataService.getCfWorkerEnabled();
    final resolvedIp = CfOptimizerHttpOverrides.getResolvedManualIp();
    // 优选 IP 启用开关关 / 没填 IP → 强制 null (走系统 DNS)
    final preferIp = (preferIpEnabled && resolvedIp != null && resolvedIp.isNotEmpty)
        ? resolvedIp
        : null;
    final fetchStart = DateTime.now();

    Socket? upstream;
    try {
      // v2.0.68: 正确的 TLS SNI 做法
      //   SecureSocket.connect 没有 host: 命名参数 (编译错误).
      //   正确: Socket.connect(ip, 443) 建 TCP, 再 SecureSocket.secure(socket, host: domain)
      //   升级 TLS. host 参数控制 SNI + 证书验证域名.
      if (preferIp != null && preferIp.isNotEmpty) {
        // 填了优选 IP: TCP 连优选 IP, TLS SNI = workerDomain
        final tcpSocket = await Socket.connect(
          preferIp,
          443,
          timeout: const Duration(seconds: 10),
        );
        try {
          tcpSocket.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        upstream = await SecureSocket.secure(tcpSocket, host: workerDomain);
      } else {
        // 没配优选 IP: 走系统 DNS (SNI = workerDomain 自动)
        upstream = await SecureSocket.connect(
          workerDomain,
          443,
          timeout: const Duration(seconds: 10),
        );
        try {
          upstream.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
      }

      // 2. 发 HTTP/1.1 请求 (Host header = workerDomain)
      final ua = state.headers['user-agent'] ??
          'Mozilla/5.0 (Linux; Android 13; Mobile) LunaTV/1.0';
      final range = state.headers['range'];
      final reqBuf = StringBuffer();
      reqBuf.write('GET $target HTTP/1.1\r\n');
      reqBuf.write('Host: $workerDomain\r\n');
      reqBuf.write('User-Agent: $ua\r\n');
      reqBuf.write('Accept: */*\r\n');
      reqBuf.write('Connection: close\r\n');
      if (range != null && range.isNotEmpty) {
        reqBuf.write('Range: $range\r\n');
      }
      reqBuf.write('\r\n');
      upstream.add(utf8.encode(reqBuf.toString()));
      await upstream.flush();

      // 3. 读响应头 (逐行读直到空行)
      final reader = _SocketReader(upstream);
      final headerLines = <String>[];
      while (true) {
        final line = await reader.readLine();
        if (line == null) break; // EOF
        if (line.isEmpty) break; // 空行 = 头结束
        headerLines.add(line);
      }

      if (headerLines.isEmpty) {
        throw Exception('upstream 返回空响应');
      }

      // 解析状态行 + 头
      final statusLine = headerLines.first;
      final statusParts = statusLine.split(' ');
      final statusCode = statusParts.length >= 2 ? int.tryParse(statusParts[1]) ?? 502 : 502;
      final headers = <String, String>{};
      for (var i = 1; i < headerLines.length; i++) {
        final idx = headerLines[i].indexOf(':');
        if (idx > 0) {
          final key = headerLines[i].substring(0, idx).trim().toLowerCase();
          final val = headerLines[i].substring(idx + 1).trim();
          headers[key] = val;
        }
      }

      final contentType = headers['content-type'] ?? '';
      final isM3u8 = contentType.contains('mpegurl') ||
          contentType.contains('m3u8') ||
          target.contains('/m3u8');
      final contentLength = int.tryParse(headers['content-length'] ?? '');
      final isChunked = (headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked');

      if (isM3u8) {
        // v2.0.69: 先发响应头 (chunked), 让 libmpv 不会 5 秒超时放弃.
        //   之前: 等 worker body 读完重写完才发响应头 → 优选 IP 慢 (6s) 时
        //         libmpv 5s 超时放弃 ("header 阶段都没数据" + "Failed to open").
        //   现在: worker 响应头一到立刻发给 libmpv (Transfer-Encoding: chunked),
        //         body 读完重写后用一个 chunk 发出. libmpv 收到响应头就不会超时.
        final headerSentAt = DateTime.now();
        final respBuf = StringBuffer();
        respBuf.write('HTTP/1.1 $statusCode OK\r\n');
        respBuf.write('Content-Type: $contentType\r\n');
        respBuf.write('Transfer-Encoding: chunked\r\n');
        respBuf.write('Access-Control-Allow-Origin: *\r\n');
        respBuf.write('Connection: close\r\n');
        respBuf.write('\r\n');
        client.add(utf8.encode(respBuf.toString()));
        await client.flush();

        // 读完整 body, 重写 https://worker/ → http://127.0.0.1:PORT/
        final bodyBytes = await reader.readBody(contentLength, isChunked);
        final body = utf8.decode(bodyBytes);
        final port = _port;
        final localBase = 'http://127.0.0.1:$port';
        final workerBase = 'https://$workerDomain';
        // v2.0.92: 改写 URL 前先在 worker 域 m3u8 上做 ad 段过滤 (基于原 host)
        //   原因: 用户反馈"播放到广告位卡住几秒再跳过" — 之前的方案是
        //   libmpv 已经加载了 ad 段, duration 跳变触发 seek 回去, 中间有几秒
        //   广告播放. 现在改在 m3u8 重写层就物理删除 ad 段, libmpv 根本看不到.
        //   过滤规则: 跟 m3u8_service._looksLikeAdSegment 一致 — URL 含广告
        //   关键词 (/ad/, /ads/, doubleclick, googlevideo 等) 或 host 跟
        //   m3u8 的 base host 跨域.
        final filtered = _stripAdsFromM3u8(body, workerDomain);
        final rewritten = filtered.replaceAll(workerBase, localBase);
        final rewrittenBytes = utf8.encode(rewritten);

        // chunked: 长度行 (hex) + 数据 + \r\n + 结束 chunk (0\r\n\r\n)
        client.add(utf8.encode('${rewrittenBytes.length.toRadixString(16)}\r\n'));
        client.add(rewrittenBytes);
        client.add(utf8.encode('\r\n0\r\n\r\n'));
        await client.flush();
        final bodyMs = DateTime.now().difference(headerSentAt).inMilliseconds;
      } else {
        // 非 m3u8 (.ts / .mp4): 流式转发
        final respBuf = StringBuffer();
        respBuf.write('HTTP/1.1 $statusCode OK\r\n');
        if (contentLength != null) {
          respBuf.write('Content-Length: $contentLength\r\n');
        }
        final ct = headers['content-type'];
        if (ct != null) respBuf.write('Content-Type: $ct\r\n');
        final cr = headers['content-range'];
        if (cr != null) respBuf.write('Content-Range: $cr\r\n');
        respBuf.write('Access-Control-Allow-Origin: *\r\n');
        respBuf.write('Connection: close\r\n');
        respBuf.write('\r\n');
        client.add(utf8.encode(respBuf.toString()));
        await client.flush();

        // 流式转发 body
        final totalBytes = await reader.streamTo(client);
      }

      // 关闭连接
      try {
        await upstream.flush();
        upstream.destroy();
      } catch (_) {}
      try {
        await client.flush();
        client.close();
      } catch (_) {}
    } catch (e) {
      try {
        upstream?.destroy();
      } catch (_) {}
      _sendHttpError(client, 502, 'Local proxy error: $e', closeAll);
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
    // v2.0.58: 记 host 给 closeAll 日志
    state.host = host;

    // v2.0.19: 借鉴 edgetunnel 预加载竞速拨号, 同时拨 Top3 优选 IP
    // v2.0.34: 改用 getTopNIpsForVideoProxy, 手动优选 IP 优先 (单 IP)
    // v2.0.46: 手动 IP 模式触发一次 host DNS 解析 (fire-and-forget),
    //   之后 _connectRace 拿候选时 host DNS 已就绪, 走 [host_ips..., manual],
    //   race 拨 host IPs 跟 SNI 匹配 → TLS 成功, 解决"162.159.x.x 静态
    //   IP TCP 拨上但 TLS 失败 → 0KB"问题
    // v2.0.54 日志: CONNECT 路径
    CfOptimizerHttpOverrides.maybeResolveHostEagerly(host);
    final topIps = CfOptimizerHttpOverrides.getTopNIpsForVideoProxy(host, 3);
    try {
      final backend = await _connectRace(host, port, topIps);
      client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
      await client.flush();
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
    // v2.0.58: 记 host 给 closeAll 日志
    state.host = host;
    // v2.0.58: 提取 path 后缀, 日志里区分 m3u8 / .ts / 其他 (4s bug 定位用)
    final reqPath = uri.path.isEmpty ? '/' : uri.path;

    // v2.0.19: 借鉴 edgetunnel 预加载竞速拨号
    // v2.0.34: 改用 getTopNIpsForVideoProxy, 手动优选 IP 优先 (单 IP)
    // v2.0.46: 手动 IP 模式触发一次 host DNS 解析 (跟 _onClientConnection 一致)
    // v2.0.54 日志: HTTP 代理路径
    // v2.0.58: 加 reqPath 区分请求类型
    CfOptimizerHttpOverrides.maybeResolveHostEagerly(host);
    final topIps = CfOptimizerHttpOverrides.getTopNIpsForVideoProxy(host, 3);

    // v2.0.19: 修 bug — request line + Host header 都用原 host, 不要用 IP
    // IP 只用来做 TCP 路由, 服务端通过 Host header 找 vhost
    // v2.0.25 修: 请求行用相对 path, 不用绝对 URI
    //   旧代码 '${state.method} $uri HTTP/1.1' 会生成
    //   'GET http://video.cdn.com/path HTTP/1.1' (absolute-form)
    //   这是代理格式, 源服务器不认 → 返回 400 → 没数据 → "没速度"
    //   正确格式: 'GET /path?query HTTP/1.1' (origin-form) + Host header
    // v2.0.58: 复用上面的 reqPath, 不再重复声明
    final requestLine =
        '${state.method} $reqPath${uri.query.isEmpty ? '' : '?${uri.query}'} HTTP/1.1';

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
  // v2.0.58: 解析出的 host (closeAll 日志用, 看是 m3u8 还是 .ts 段)
  String? host;
  int headerEnd = 0;
  final Map<String, String> headers = {};
  List<int> buffer = [];
  List<int> pendingBodyBytes = [];
}

/// v2.0.66: Socket 读取器, 封装 socket + 剩余 buffer.
///   用于 _handleLocalHttp 读 HTTP 响应 (readLine / readBody / streamTo).
///   解决 socket.first 丢数据 + 逐字节读慢的问题.
class _SocketReader {
  final Socket _socket;
  final List<int> _buf = [];
  bool _eof = false;
  final StreamIterator<List<int>> _iter;

  _SocketReader(this._socket) : _iter = StreamIterator(_socket);

  /// 读一行 (以 \r\n 或 \n 结尾), 返回不含换行符的内容. EOF 返回 null.
  Future<String?> readLine() async {
    final line = <int>[];
    while (true) {
      if (_buf.isEmpty) {
        if (_eof) {
          return line.isEmpty ? null : utf8.decode(line);
        }
        if (!await _iter.moveNext()) {
          _eof = true;
          return line.isEmpty ? null : utf8.decode(line);
        }
        _buf.addAll(_iter.current);
      }
      var consumed = 0;
      while (consumed < _buf.length) {
        final b = _buf[consumed];
        if (b == 0x0D) {
          // \r
          consumed++;
          if (consumed < _buf.length) {
            if (_buf[consumed] == 0x0A) consumed++; // \r\n
          }
          // 移除已读
          _buf.removeRange(0, consumed);
          return utf8.decode(line);
        }
        if (b == 0x0A) {
          consumed++;
          _buf.removeRange(0, consumed);
          return utf8.decode(line);
        }
        line.add(b);
        consumed++;
      }
      _buf.clear();
    }
  }

  /// 读完整 body (Content-Length 或 chunked 或 EOF)
  Future<List<int>> readBody(int? contentLength, bool isChunked) async {
    final out = <int>[];
    if (isChunked) {
      while (true) {
        final sizeLine = await readLine();
        if (sizeLine == null) break;
        final size = int.tryParse(sizeLine.trim(), radix: 16) ?? 0;
        if (size == 0) {
          await readLine();
          break;
        }
        out.addAll(await readN(size));
        await readLine();
      }
    } else if (contentLength != null) {
      out.addAll(await readN(contentLength));
    } else {
      while (!_eof) {
        if (_buf.isNotEmpty) {
          out.addAll(_buf);
          _buf.clear();
        }
        if (!await _iter.moveNext()) {
          _eof = true;
        } else {
          out.addAll(_iter.current);
        }
      }
    }
    return out;
  }

  /// 精确读 N 字节
  Future<List<int>> readN(int n) async {
    final out = <int>[];
    while (out.length < n) {
      if (_buf.isEmpty) {
        if (!await _iter.moveNext()) {
          _eof = true;
          break;
        }
        _buf.addAll(_iter.current);
      }
      final take = n - out.length;
      if (_buf.length <= take) {
        out.addAll(_buf);
        _buf.clear();
      } else {
        out.addAll(_buf.sublist(0, take));
        _buf.removeRange(0, take);
      }
    }
    return out;
  }

  /// 流式转发剩余 body 到 [sink], 返回总字节数
  Future<int> streamTo(Socket sink) async {
    var total = 0;
    // 先发 buffer 里剩余的
    if (_buf.isNotEmpty) {
      sink.add(_buf);
      await sink.flush();
      total += _buf.length;
      _buf.clear();
    }
    while (!_eof) {
      if (!await _iter.moveNext()) {
        _eof = true;
        break;
      }
      sink.add(_iter.current);
      await sink.flush();
      total += _iter.current.length;
    }
    return total;
  }
}
