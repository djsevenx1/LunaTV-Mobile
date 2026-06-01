import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';

/// M3U8 解析和测速服务
class M3U8Service {
  final Dio _dio = Dio();

  M3U8Service() {
    // 配置 Dio
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
    _dio.options.headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
  }


  /// 并发获取流的核心信息：分辨率、下载速度、延迟
  Future<Map<String, dynamic>> getStreamInfo(String streamUrl) async {
    try {
      // 获取片段列表
      final segments = await _getSegmentUrls(streamUrl);
      
      if (segments.isEmpty) {
        return {
          'resolution': '未知',
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': '未找到视频片段',
        };
      }
      
      // 并发执行三个任务
      final futures = await Future.wait([
        _getResolutionFromM3U8(streamUrl),
        _measureLatency(segments.first),
        _measureDownloadSpeed(segments),
      ]);
      
      final resolutionData = futures[0] as Map<String, int>;
      final latency = futures[1] as int;
      final downloadSpeedKBps = futures[2] as double;
      
      return {
        'resolution': resolutionData,
        'downloadSpeed': downloadSpeedKBps,
        'latency': latency,
        'success': true,
        'error': '',
      };
      
    } catch (e) {
      return {
        'resolution': {'width': 0, 'height': 0},
        'downloadSpeed': 0.0,
        'latency': 0,
        'success': false,
        'error': e.toString(),
      };
    }
  }



  /// 获取M3U8流的片段URL列表
  Future<List<String>> _getSegmentUrls(String m3u8Url) async {
    try {
      final response = await _dio.get(m3u8Url);
      final content = response.data as String;
      return _parseSegmentsFromContent(content, m3u8Url);
    } catch (e) {
      return [];
    }
  }

  /// 从M3U8内容中解析片段URL
  List<String> _parseSegmentsFromContent(String content, String baseUrl) {
    final lines = content.split('\n').map((line) => line.trim()).toList();
    final segments = <String>[];
    
    for (final line in lines) {
      // 跳过注释和空行
      if (line.startsWith('#') || line.isEmpty) {
        continue;
      }
      
      // 这应该是一个片段URL
      final absoluteUrl = _resolveUrl(line, baseUrl);
      segments.add(absoluteUrl);
    }
    
    return segments;
  }

  /// 解析相对 URL 为绝对 URL
  String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    
    final baseUri = Uri.parse(baseUrl);
    if (url.startsWith('/')) {
      // 绝对路径
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}$url';
    } else {
      // 相对路径
      final basePath = baseUri.path.substring(0, baseUri.path.lastIndexOf('/') + 1);
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}$basePath$url';
    }
  }

  /// 测量网络延迟（RTT - Round Trip Time）
  Future<int> _measureLatency(String url) async {
    try {
      // 创建临时的 Dio 实例用于延迟测量
      final tempDio = Dio();
      tempDio.options.connectTimeout = const Duration(seconds: 5);
      tempDio.options.receiveTimeout = const Duration(seconds: 5);
      tempDio.options.headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      };
      
      // 使用 HEAD 请求测量延迟，减少数据传输
      final stopwatch = Stopwatch()..start();
      
      try {
        await tempDio.head(url);
        stopwatch.stop();
        final latency = stopwatch.elapsedMilliseconds;
        return latency;
      } on DioException catch (dioError) {
        // 对于 DioException，检查是否收到了服务器响应
        if (dioError.response != null) {
          // 有响应，说明网络连接成功，只是状态码不是 2xx
          stopwatch.stop();
          final latency = stopwatch.elapsedMilliseconds;
          return latency;
        } else {
          // 没有响应，说明连接失败
          return -1;
        }
      }
      
    } catch (e) {
      return -1; // 返回 -1 表示测量失败
    }
  }


  /// 从 M3U8 文件获取分辨率
  Future<Map<String, int>> _getResolutionFromM3U8(String m3u8Url) async {
    try {
      final response = await _dio.get(m3u8Url);
      final content = response.data as String;
      final lines = content.split('\n').map((line) => line.trim()).toList();
      
      for (final line in lines) {
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          final params = <String, String>{};
          final parts = line.substring('#EXT-X-STREAM-INF:'.length).split(',');
          
          for (final part in parts) {
            final keyValue = part.split('=');
            if (keyValue.length == 2) {
              params[keyValue[0].trim()] = keyValue[1].trim();
            }
          }
          
          if (params.containsKey('RESOLUTION')) {
            final resolution = params['RESOLUTION']!;
            final dimensions = resolution.split('x');
            if (dimensions.length == 2) {
              return {
                'width': int.tryParse(dimensions[0]) ?? 0,
                'height': int.tryParse(dimensions[1]) ?? 0,
              };
            }
          }
        }
      }
      
      return {'width': 0, 'height': 0};
    } catch (e) {
      return {'width': 0, 'height': 0};
    }
  }

  /// 测量下载速度
  Future<double> _measureDownloadSpeed(List<String> segments) async {
    try {
      // 使用前3个片段进行测速
      final segmentsToTest = segments.take(3).toList();
      
      final stopwatch = Stopwatch()..start();
      int totalBytes = 0;
      int successfulDownloads = 0;
      
      // 并发下载片段
      final futures = segmentsToTest.map((segmentUrl) async {
        try {
          final response = await _dio.get(
            segmentUrl,
            options: Options(
              responseType: ResponseType.bytes,
              receiveTimeout: const Duration(seconds: 5),
            ),
          );
          
          final bytes = (response.data as Uint8List).length;
          totalBytes += bytes;
          successfulDownloads++;
        } catch (e) {
          // 忽略下载失败的片段
        }
      });
      
      await Future.wait(futures);
      stopwatch.stop();
      
      if (successfulDownloads == 0 || totalBytes == 0) {
        return 0.0;
      }
      
      // 计算下载速度 (KB/s)
      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
      final downloadSpeed = (totalBytes / 1024) / elapsedSeconds;
      
      return downloadSpeed;
    } catch (e) {
      return 0.0;
    }
  }

  /// 批量获取所有源的流信息并选择最佳源
  Future<Map<String, dynamic>> preferBestSource(List<dynamic> allSources) async {
    if (allSources.isEmpty) {
      return {
        'bestSource': null,
        'allSourcesSpeed': <String, Map<String, dynamic>>{},
        'error': '没有可用的源',
      };
    }
    
    if (allSources.length == 1) {
      return {
        'bestSource': allSources.first,
        'allSourcesSpeed': <String, Map<String, dynamic>>{},
        'error': '',
      };
    }
    
    // 为每个源选择要测试的集数链接
    final testUrls = <String, String>{}; // sourceId -> episodeUrl
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      String episodeUrl;
      
      // 选择第二集链接，如果没有第二集则选择第一集
      if (source.episodes.length >= 2) {
        episodeUrl = source.episodes[1]; // 第二集
      } else if (source.episodes.isNotEmpty) {
        episodeUrl = source.episodes[0]; // 第一集
      } else {
        continue; // 跳过没有集数的源
      }
      
      testUrls[sourceId] = episodeUrl;
    }
    
    // 并发获取所有源的流信息
    final futures = testUrls.entries.map((entry) async {
      final sourceId = entry.key;
      final episodeUrl = entry.value;
      
      try {
        final streamInfo = await getStreamInfo(episodeUrl).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            return {
              'resolution': {'width': 0, 'height': 0},
              'downloadSpeed': 0.0,
              'latency': 0,
              'success': false,
              'error': '获取流信息超时',
            };
          },
        );
        return MapEntry(sourceId, streamInfo);
      } catch (e) {
        return MapEntry(sourceId, {
          'resolution': {'width': 0, 'height': 0},
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': e.toString(),
        });
      }
    });
    
    // 等待所有流信息获取完成
    final results = await Future.wait(futures);
    final streamInfoResults = <String, Map<String, dynamic>>{};
    for (final result in results) {
      streamInfoResults[result.key] = result.value;
    }
    
    // 找出所有有效速度的最大值，用于线性映射
    final validSpeeds = <double>[];
    final validPings = <int>[];
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      final streamInfo = streamInfoResults[sourceId];
      
      if (streamInfo != null && streamInfo['success']) {
        final downloadSpeed = streamInfo['downloadSpeed'] as double;
        final latency = streamInfo['latency'] as int;
        
        if (downloadSpeed > 0) {
          validSpeeds.add(downloadSpeed);
        }
        if (latency > 0) {
          validPings.add(latency);
        }
      }
    }
    
    // 计算基准值
    final maxSpeed = validSpeeds.isNotEmpty ? validSpeeds.reduce((a, b) => a > b ? a : b) : 1024.0; // 默认1MB/s作为基准
    final minPing = validPings.isNotEmpty ? validPings.reduce((a, b) => a < b ? a : b) : 50;
    final maxPing = validPings.isNotEmpty ? validPings.reduce((a, b) => a > b ? a : b) : 1000;
    
    // 计算每个源的评分并排序
    final sourceScores = <MapEntry<dynamic, double>>[];
    final allSourcesSpeed = <String, Map<String, dynamic>>{};
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      final streamInfo = streamInfoResults[sourceId];
      
      if (streamInfo == null || !streamInfo['success']) {
        continue; // 跳过获取失败的源
      }
      
      final downloadSpeed = streamInfo['downloadSpeed'] as double;
      final latency = streamInfo['latency'] as int;
      final resolutionData = streamInfo['resolution'] as Map<String, int>;
      
      // 转换分辨率为标准格式
      final resolution = _convertResolutionToString(resolutionData);
      
      // 计算综合评分
      final score = _calculateSourceScore(
        resolution,
        downloadSpeed,
        latency,
        maxSpeed,
        minPing,
        maxPing,
      );
      
      sourceScores.add(MapEntry(source, score));
      
      allSourcesSpeed[sourceId] = {
        'quality': resolution,
        'loadSpeed': _formatDownloadSpeed(downloadSpeed),
        'pingTime': '${latency}ms',
      };
    }
    
    // 按综合评分排序，选择最佳播放源
    sourceScores.sort((a, b) => b.value.compareTo(a.value));
    
    final bestSource = sourceScores.isNotEmpty ? sourceScores.first.key : allSources.first;
    
    return {
      'bestSource': bestSource,
      'allSourcesSpeed': allSourcesSpeed,
      'error': '',
    };
  }

  /// 计算源的综合评分
  /// 使用线性映射算法，基于实际测速结果动态调整评分范围
  /// 包含分辨率、下载速度和网络延迟三个维度的评分
  double _calculateSourceScore(
    String quality,
    double speedKBps,
    int latencyMs,
    double maxSpeed,
    int minPing,
    int maxPing,
  ) {
    double score = 0;

    // 分辨率评分 (40% 权重)
    final qualityScore = _getQualityScore(quality);
    score += qualityScore * 0.4;

    // 下载速度评分 (40% 权重) - 基于最大速度线性映射
    final speedScore = _getSpeedScore(speedKBps, maxSpeed);
    score += speedScore * 0.4;

    // 网络延迟评分 (20% 权重) - 基于延迟范围线性映射
    final pingScore = _getPingScore(latencyMs, minPing, maxPing);
    score += pingScore * 0.2;

    return (score * 100).round() / 100.0; // 保留两位小数
  }

  /// 获取分辨率评分
  double _getQualityScore(String quality) {
    switch (quality.toLowerCase()) {
      case '4k':
      case '2160p':
        return 100;
      case '2k':
      case '1440p':
        return 85;
      case '1080p':
        return 75;
      case '720p':
        return 60;
      case '480p':
        return 40;
      case 'sd':
      case '360p':
        return 20;
      default:
        return 0;
    }
  }

  /// 获取下载速度评分
  double _getSpeedScore(double speedKBps, double maxSpeed) {
    if (speedKBps <= 0) return 30; // 无效速度给默认分
    
    // 基于最大速度线性映射，最高100分
    final speedRatio = speedKBps / maxSpeed;
    return (speedRatio * 100).clamp(0.0, 100.0);
  }

  /// 获取网络延迟评分
  double _getPingScore(int latencyMs, int minPing, int maxPing) {
    if (latencyMs <= 0) return 0; // 无效延迟给0分
    
    // 如果所有延迟都相同，给满分
    if (maxPing == minPing) return 100;
    
    // 线性映射：最低延迟=100分，最高延迟=0分
    final pingRatio = (maxPing - latencyMs) / (maxPing - minPing);
    return (pingRatio * 100).clamp(0.0, 100.0);
  }

  /// 将分辨率数据转换为标准字符串格式
  String _convertResolutionToString(Map<String, int> resolutionData) {
    final width = resolutionData['width'] ?? 0;
    final height = resolutionData['height'] ?? 0;
    
    if (width == 0 || height == 0) return '未知';
    
    // 根据经典宽度判断分辨率
    if (width >= 3840) return '4K';      // 4K: 3840x2160
    if (width >= 2560) return '2K';      // 2K: 2560x1440
    if (width >= 1920) return '1080p';   // 1080p: 1920x1080
    if (width >= 1280) return '720p';    // 720p: 1280x720
    if (width >= 854) return '480p';     // 480p: 854x480
    if (width >= 640) return '360p';     // 360p: 640x360
    
    return 'SD';
  }

  /// 格式化下载速度为字符串
  String _formatDownloadSpeed(double speedKBps) {
    if (speedKBps <= 0) return '超时';
    
    if (speedKBps >= 1024) {
      // 大于等于1MB/s，显示为MB/s
      final speedMBps = speedKBps / 1024;
      return '${speedMBps.toStringAsFixed(1)}MB/s';
    } else {
      // 小于1MB/s，显示为KB/s
      return '${speedKBps.toStringAsFixed(1)}KB/s';
    }
  }


  /// 并发测速所有源并实时回调结果
  Future<void> testSourcesWithCallback(
    List<dynamic> allSources,
    Function(String sourceId, Map<String, dynamic> speedData) onSourceCompleted, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (allSources.isEmpty) return;
    
    // 为每个源选择要测试的集数链接
    final testUrls = <String, String>{}; // sourceId -> episodeUrl
    
    for (final source in allSources) {
      final sourceId = '${source.source}_${source.id}';
      String episodeUrl;
      
      // 选择第二集链接，如果没有第二集则选择第一集
      if (source.episodes.length >= 2) {
        episodeUrl = source.episodes[1]; // 第二集
      } else if (source.episodes.isNotEmpty) {
        episodeUrl = source.episodes[0]; // 第一集
      } else {
        continue; // 跳过没有集数的源
      }
      
      testUrls[sourceId] = episodeUrl;
    }
    
    // 创建并发测速任务
    final futures = testUrls.entries.map((entry) async {
      final sourceId = entry.key;
      final episodeUrl = entry.value;
      
      try {
        final streamInfo = await getStreamInfo(episodeUrl).timeout(
          timeout,
          onTimeout: () {
            return {
              'resolution': {'width': 0, 'height': 0},
              'downloadSpeed': 0.0,
              'latency': 0,
              'success': false,
              'error': '获取流信息超时',
            };
          },
        );
        
        if (streamInfo['success']) {
          final downloadSpeed = streamInfo['downloadSpeed'] as double;
          final latency = streamInfo['latency'] as int;
          final resolutionData = streamInfo['resolution'] as Map<String, int>;
          
          // 转换分辨率为标准格式
          final resolution = _convertResolutionToString(resolutionData);
          
          final speedData = {
            'quality': resolution,
            'loadSpeed': _formatDownloadSpeed(downloadSpeed),
            'pingTime': '${latency}ms',
          };
          
          // 实时回调结果
          onSourceCompleted(sourceId, speedData);
        } else {
          // 测速失败的情况
          final speedData = {
            'quality': '未知',
            'loadSpeed': '超时',
            'pingTime': '超时',
          };
          onSourceCompleted(sourceId, speedData);
        }
      } catch (e) {
        // 异常情况
        final speedData = {
          'quality': '未知',
          'loadSpeed': '超时',
          'pingTime': '超时',
        };
        onSourceCompleted(sourceId, speedData);
      }
    });
    
    // 并发执行所有测速任务，每个任务完成后会立即触发回调
    await Future.wait(futures);
  }

  /// 释放资源
  void dispose() {
    _dio.close();
  }
}

