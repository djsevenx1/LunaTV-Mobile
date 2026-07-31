import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/search_resource.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/downstream_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';

/// SSE 搜索服务
class SSESearchService {
  // http.Client? _client; // v2.6.26: 删除 _client 字段, 改用 ApiService
  //   共享的 _httpClient (保持 keep-alive 连接池). 之前每次搜索都新建
  //   http.Client() = 新 IOClient = 新 HttpClient, 每次都要重新建 TCP 握手
  //   + TLS 协商, 冷启首搜 200-1000ms. 共享 client 后同 host 请求走同连接池,
  //   首搜省掉这层握手, 体感更跟手.
  StreamSubscription? _subscription;
  StreamController<List<SearchResult>>? _incrementalResultsController;
  StreamController<String>? _errorController;
  StreamController<SearchProgress>? _progressController;

  bool _isConnected = false;
  String? _currentQuery;
  final Map<String, String> _sourceErrors = {};
  String _buffer = ''; // 用于缓冲不完整的 UTF-8 字符
  int _completedSources = 0; // 跟踪完成的源数量
  int _totalSources = 0; // 总源数量
  Timer? _timeoutTimer; // 超时定时器
  // v2.6.16: 每个源的结果数 — 用户反馈「奈飞工厂源app搜不到内容」, 但
  //   实际是源 API 本身就没数据. 加这个 map 在搜索完成后显示每个源搜出
  //   多少条, 用户能区分「源没数据 (0 条)」vs 「app 没搜这个源 (缺失)」.
  //   Map<sourceKey, count>, count = 0 表示源被调用了但 API 返回 0 条.
  final Map<String, int> _sourceResultCounts = {};

  /// 获取每个源的结果数 (key = source.key, value = 命中结果数)
  Map<String, int> get sourceResultCounts =>
      Map<String, int>.from(_sourceResultCounts);

  /// 获取增量结果流
  Stream<List<SearchResult>> get incrementalResultsStream =>
      _incrementalResultsController?.stream ?? const Stream.empty();

  /// 获取错误流
  Stream<String> get errorStream =>
      _errorController?.stream ?? const Stream.empty();

  /// 获取进度流
  Stream<SearchProgress> get progressStream =>
      _progressController?.stream ?? const Stream.empty();

  /// 是否已连接
  bool get isConnected => _isConnected;

  /// 当前搜索查询
  String? get currentQuery => _currentQuery;

  /// 本地搜索
  Future<void> localSearch(String query) async {
    try {
      // 检查是否是本地模式
      final isLocalMode = await UserDataService.getIsLocalMode();

      // 获取搜索资源列表
      final allResources = isLocalMode
          ? await LocalModeStorageService.getSearchSources()
          : await ApiService.getSearchResources();

      // 过滤掉被禁用的资源
      final resources =
          allResources.where((resource) => !resource.disabled).toList();

      if (resources.isEmpty) {
        _errorController?.add('没有可用的搜索资源');
        _isConnected = false;
        return;
      }

      _totalSources = resources.length;
      _completedSources = 0;
      _sourceResultCounts.clear();

      _progressController?.add(SearchProgress(
        totalSources: _totalSources,
        completedSources: 0,
        currentSource: null,
        isComplete: false,
      ));

      // 并发调用所有资源的搜索，每个调用增加 20 秒超时
      final searchFutures = resources.map((resource) {
        return _searchSingleResource(resource, query);
      }).toList();

      // 等待所有搜索完成
      await Future.wait(searchFutures);

      // 发送完成事件
      _progressController?.add(SearchProgress(
        totalSources: _totalSources,
        completedSources: _totalSources,
        currentSource: null,
        isComplete: true,
      ));

      _isConnected = false;
    } catch (e) {
      _errorController?.add('本地搜索异常: ${e.toString()}');
      _isConnected = false;
    }
  }

  /// 搜索单个资源
  Future<void> _searchSingleResource(
      SearchResource resource, String query) async {
    try {
      // 调用 searchFromApi 并设置 20 秒超时
      final results = await DownstreamService.searchFromApi(resource, query)
          .timeout(const Duration(seconds: 20));

      // 增加完成计数
      _completedSources++;

      // v2.6.16: 记录该源的结果数 (含 0 条, 让用户知道源被调用了但没数据)
      _sourceResultCounts[resource.key] = results.length;

      // 发送结果事件
      if (results.isNotEmpty) {
        _incrementalResultsController?.add(results);
      }

      // 发送进度更新
      _progressController?.add(SearchProgress(
        totalSources: _totalSources,
        completedSources: _completedSources,
        currentSource: resource.name,
        isComplete: false,
      ));
    } on TimeoutException {
      // 超时处理
      _completedSources++;
      _sourceErrors[resource.key] = '搜索超时（20秒）';
      // v2.6.16: 超时也算源完成, 记 0 条
      _sourceResultCounts[resource.key] ??= 0;

      // 发送错误进度更新
      _progressController?.add(SearchProgress(
        totalSources: _totalSources,
        completedSources: _completedSources,
        currentSource: resource.name,
        isComplete: false,
        error: '搜索超时（20秒）',
      ));
    } catch (e) {
      // 其他错误处理
      _completedSources++;
      _sourceErrors[resource.key] = e.toString();
      // v2.6.16: 错误也算源完成, 记 0 条
      _sourceResultCounts[resource.key] ??= 0;

      // 发送错误进度更新
      _progressController?.add(SearchProgress(
        totalSources: _totalSources,
        completedSources: _completedSources,
        currentSource: resource.name,
        isComplete: false,
        error: e.toString(),
      ));
    }
  }

  /// 开始搜索
  Future<void> startSearch(String query) async {
    if (query.trim().isEmpty) {
      throw Exception('搜索查询不能为空');
    }

    // v2.6.32: 快速取消旧连接, 不 await stopSearch(). 之前 await stopSearch()
    //   等旧 SSE 流完全关闭 + 3 个 StreamController.close() 完成, 如果旧
    //   搜索还在接收数据, cancel + close 可能需要几十毫秒. 现在直接 cancel
    //   + 置 null, 新搜索立即开始. 有 generation guard 保证旧结果不混入.
    _subscription?.cancel();
    _subscription = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _isConnected = false;

    // 旧流控制器直接置 null (GC 回收), 不 await close
    _incrementalResultsController = null;
    _errorController = null;
    _progressController = null;

    _currentQuery = query.trim();
    _sourceErrors.clear();
    _sourceResultCounts.clear();
    _completedSources = 0;

    // 创建新的流控制器
    _incrementalResultsController =
        StreamController<List<SearchResult>>.broadcast();
    _errorController = StreamController<String>.broadcast();
    _progressController = StreamController<SearchProgress>.broadcast();

    _isConnected = true;

    // v2.6.32: 20s 超时保留作为兜底, 但正常情况下后端 1-3s 就推回结果.
    _timeoutTimer = Timer(const Duration(seconds: 20), () {
      if (_isConnected) {
        _handleTimeout();
      }
    });

    // v2.6.25: 4 个 await UserDataService.* → 4 个同步读. 之前 4 个串行
    //   await SharedPreferences.getInstance() (磁盘 IO) 拖慢 SSE 启动
    //   0.5-2s, 体感比 Selene 慢根因. 现在:
    //   - getIsLocalModeSync / getLocalSearchSync: 走 _isLocalModeCache /
    //     _localSearchCache 内存, 0ms
    //   - _serverUrlCache / _cookiesCache: 走 UserDataService 内部 sync
    //     getter, 0ms (原代码 line 120-127 已有 _serverUrlCache,
    //     line 147-154 已有 _cookiesCache)
    //   warmup 阶段 (UserDataService.warmupUserDataConfig 启动时调一次)
    //   已经预热这 4 个缓存, 这里同步读全是 0ms.
    final isLocalMode = UserDataService.getIsLocalModeSync();
    if (isLocalMode) {
      localSearch(query);
      return;
    }

    final isLocalSearch = UserDataService.getLocalSearchSync();
    if (isLocalSearch) {
      localSearch(query);
      return;
    }

    try {
      // 获取服务器地址和认证信息 — 同步读, 走 _serverUrlCache / _cookiesCache
      //   (warmup 已预热). 之前 await 是串行, 现在 0ms.
      final baseUrl = UserDataService.getServerUrlSync();
      final cookies = UserDataService.getCookiesSync();

      if (baseUrl == null) {
        throw Exception('服务器地址未配置，请先登录');
      }

      if (cookies == null) {
        throw Exception('用户未登录');
      }

      // 构建 SSE URL
      final baseUri = Uri.parse(baseUrl);
      final sseUri = baseUri.replace(
        path: '/api/search/ws',
        queryParameters: {
          'q': _currentQuery!,
        },
      );

      // v2.6.26: 用 ApiService.sharedHttpClient 共享 client 发起 SSE 请求
      //   (保连接池 + keep-alive). 之前 _client = http.Client() 每次新建
      //   IOClient → 新 HttpClient → 冷启首搜要重做 TCP 握手 + TLS 协商,
      //   200-1000ms 延迟, 体感首搜比 Selene 慢 200-1000ms 根因之一. 现在
      //   跟普通 GET/POST 一样走共享 client, 多次搜索间复用同 host 连接池,
      //   首搜省 0.2-1s.
      final client = ApiService.sharedHttpClient;
      final request = http.Request('GET', sseUri);
      request.headers.addAll({
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Cookie': cookies,
      });

      _subscription = client.send(request).asStream().listen(
        _handleSSEResponse,
        onError: (error) {
          // v2.6.31: 之前把 connection closed / clientexception / connection
          //   terminated 全静默 return, SSE 连接失败时用户看不到任何错误,
          //   只转 20s 超时. 现在: 如果没收到任何结果 (completedSources=0)
          //   且没收到 complete 事件, 当成真错误报给用户. 如果已经收到了
          //   结果/complete, 说明是正常关流, 静默忽略.
          final errorString = error.toString().toLowerCase();
          final isConnectionClose = errorString.contains('connection closed') ||
              errorString.contains('clientexception') ||
              errorString.contains('connection terminated');
          if (isConnectionClose && _completedSources > 0) {
            // 正常关流 (server close 后 Dart http 抛 ClientException), 有结果, 忽略
            return;
          }
          // 真错误 (连接失败 / 0 结果时断开) — 报给用户
          _handleError(error);
        },
        onDone: _handleDone,
      );
    } catch (e) {
      _isConnected = false;

      // 检查是否是连接关闭错误，如果是则静默处理
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('connection closed') ||
          errorString.contains('clientexception') ||
          errorString.contains('connection terminated')) {
        // 连接被关闭，这是正常情况，静默处理
        return;
      }

      _errorController?.add('连接失败: ${e.toString()}');
      rethrow;
    }
  }

  /// 处理 SSE 响应
  void _handleSSEResponse(http.StreamedResponse response) async {
    if (response.statusCode != 200) {
      // v2.6.31: 非 200 时不仅报错, 还要发 complete 事件关掉 loading.
      //   之前只加 error 不发 complete, search_screen 的 _isLoading
      //   虽然 errorStream 会关, 但如果 errorStream 监听有 race condition
      //   (progressStream 先到), 可能漏关. 双保险.
      _errorController?.add('SSE 连接失败: ${response.statusCode}');
      _isConnected = false;
      _progressController?.add(SearchProgress(
        totalSources: _totalSources,
        completedSources: _totalSources,
        currentSource: null,
        isComplete: true,
        error: 'HTTP ${response.statusCode}',
      ));
      return;
    }

    // 重置缓冲区
    _buffer = '';

    // 使用流式 UTF-8 解码器，自动处理跨 chunk 的多字节字符
    final utf8Decoder = const Utf8Decoder(allowMalformed: false);

    // 流式处理 SSE 数据
    await for (final chunk in response.stream.transform(utf8Decoder)) {
      try {
        // 将新数据添加到缓冲区
        _buffer += chunk;

        // 按行分割并处理
        final lines = _buffer.split('\n');

        // 保留最后一行（可能不完整）
        if (lines.isNotEmpty) {
          _buffer = lines.last;
          lines.removeLast();
        }

        for (final line in lines) {
          if (line.trim().isEmpty) continue;

          // SSE 格式: data: {...}
          if (line.startsWith('data: ')) {
            final jsonStr = line.substring(6); // 移除 'data: ' 前缀
            _handleSSEData(jsonStr);
          }
        }
      } catch (e) {
        // 如果解码失败，尝试跳过这个块
        continue;
      }
    }
  }

  /// 处理 SSE 数据
  void _handleSSEData(String jsonStr) {
    try {
      final data = json.decode(jsonStr);

      final event = SearchEvent.fromJson(data as Map<String, dynamic>);

      switch (event.type) {
        case SearchEventType.start:
          _handleStartEvent(event as SearchStartEvent);
          break;
        case SearchEventType.sourceResult:
          _handleSourceResultEvent(event as SearchSourceResultEvent);
          break;
        case SearchEventType.sourceError:
          _handleSourceErrorEvent(event as SearchSourceErrorEvent);
          break;
        case SearchEventType.complete:
          _handleCompleteEvent(event as SearchCompleteEvent);
          break;
      }
    } catch (e) {
      _errorController?.add('消息解析失败: ${e.toString()}');
    }
  }

  /// 处理开始事件
  void _handleStartEvent(SearchStartEvent event) {
    _totalSources = event.totalSources;
    _progressController?.add(SearchProgress(
      totalSources: event.totalSources,
      completedSources: 0,
      currentSource: null,
      isComplete: false,
    ));
  }

  /// 处理搜索结果事件
  void _handleSourceResultEvent(SearchSourceResultEvent event) {
    _completedSources++;

    // v2.6.16: 记录该源的结果数 (后端 SSE 路径)
    _sourceResultCounts[event.source] = event.results.length;

    // 只发送增量结果更新，避免全量重渲染
    if (event.results.isNotEmpty) {
      _incrementalResultsController?.add(List.from(event.results));
    }

    // 更新进度（无论是否有结果都要更新）
    _progressController?.add(SearchProgress(
      totalSources: _totalSources,
      completedSources: _completedSources,
      currentSource: event.sourceName,
      isComplete: false,
    ));
  }

  /// 处理搜索错误事件
  void _handleSourceErrorEvent(SearchSourceErrorEvent event) {
    _sourceErrors[event.source] = event.error;

    // 错误也算源完成，累计进度
    _completedSources++;

    // 更新进度
    _progressController?.add(SearchProgress(
      totalSources: _totalSources,
      completedSources: _completedSources,
      currentSource: event.sourceName,
      isComplete: false,
      error: event.error,
    ));
  }

  /// 处理完成事件
  void _handleCompleteEvent(SearchCompleteEvent event) {
    // 如果完成源数小于总源数，说明有些源没有发送结果事件
    // 将完成源数设置为总源数
    if (_completedSources < _totalSources) {
      _completedSources = _totalSources;
    }

    // 发送最终完成状态
    _progressController?.add(SearchProgress(
      totalSources: _totalSources,
      completedSources: _completedSources,
      currentSource: null,
      isComplete: true,
    ));

    // 搜索完成，关闭连接
    _closeConnection();
  }

  /// 处理超时
  void _handleTimeout() {
    // 如果完成源数小于总源数，说明有些源没有发送结果事件
    // 将完成源数设置为总源数
    if (_completedSources < _totalSources) {
      _completedSources = _totalSources;
    }

    // 发送超时状态
    _progressController?.add(SearchProgress(
      totalSources: _totalSources,
      completedSources: _completedSources,
      currentSource: null,
      isComplete: true,
    ));

    _errorController?.add('搜索超时（15秒）');
    _closeConnection();
  }

  /// 关闭连接
  void _closeConnection() {
    _isConnected = false;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    // v2.6.26: 共享 ApiService._httpClient, 不调 client.close() (会关掉整
    //   个共享 client 影响其他请求). 取消 subscription 让 SSE 流自然关闭.
  }

  /// 处理 SSE 错误
  void _handleError(error) {
    _isConnected = false;

    // v2.6.31: 不再静默吞 connection closed — 如果走到这里说明是真错误
    //   (onError 里已经过滤了正常关流的情况). 报给用户 + 发 complete 事件
    //   关掉 loading, 否则 _isLoading 永远 true.
    _errorController?.add('搜索失败: ${error.toString()}');

    // v2.6.31: 发 complete 事件关掉 loading, 否则 search_screen 的
    //   _isLoading 永远 true (只有 progress.isComplete 或 error 才关)
    if (_completedSources < _totalSources) {
      _completedSources = _totalSources;
    }
    _progressController?.add(SearchProgress(
      totalSources: _totalSources,
      completedSources: _completedSources,
      currentSource: null,
      isComplete: true,
      error: error.toString(),
    ));
  }

  /// 处理 SSE 关闭
  void _handleDone() {
    _isConnected = false;
    // v2.6.31: 流关闭时如果还没发 complete 事件, 补发一个. 之前 _handleDone
    //   只设 _isConnected=false, 不发 progress.isComplete, 如果 server 关流
    //   但 complete 事件没被处理到 (网络中断 / server crash / Dart http 提前
    //   关流), search_screen 的 _isLoading 永远 true, 用户卡在"搜索中...".
    //   现在补发 complete, 确保 _isLoading 一定被关掉.
    if (_totalSources > 0 && _completedSources < _totalSources) {
      _completedSources = _totalSources;
      _progressController?.add(SearchProgress(
        totalSources: _totalSources,
        completedSources: _completedSources,
        currentSource: null,
        isComplete: true,
      ));
    }
  }

  /// 停止搜索
  Future<void> stopSearch() async {
    await _subscription?.cancel();
    _subscription = null;

    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    // v2.6.26: 共享 ApiService._httpClient, 不调 client.close() (会关掉
    //   整个共享 client, 影响其他请求). 取消 subscription + 依赖 stream
    //   onDone 自然结束即可.

    _isConnected = false;
    _currentQuery = null;

    // 关闭流控制器
    await _incrementalResultsController?.close();
    await _errorController?.close();
    await _progressController?.close();

    _incrementalResultsController = null;
    _errorController = null;
    _progressController = null;
  }

  /// 获取源错误信息
  Map<String, String> get sourceErrors => Map.from(_sourceErrors);

  /// 释放资源
  void dispose() {
    stopSearch();
  }
}

/// 搜索进度信息
class SearchProgress {
  final int totalSources;
  final int completedSources;
  final String? currentSource;
  final bool isComplete;
  final String? error;

  SearchProgress({
    required this.totalSources,
    required this.completedSources,
    this.currentSource,
    required this.isComplete,
    this.error,
  });

  /// 获取完成百分比
  double get progressPercentage {
    if (totalSources <= 0) return 0.0;
    return (completedSources / totalSources).clamp(0.0, 1.0);
  }

  /// 是否有错误
  bool get hasError => error != null;

  /// 获取进度描述
  String get progressDescription {
    if (isComplete) {
      return '搜索完成';
    } else if (currentSource != null) {
      return '正在搜索: $currentSource';
    } else {
      return '准备搜索...';
    }
  }
}
