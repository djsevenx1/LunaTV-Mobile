/// 短剧分类数据模型
class ShortDramaCategory {
  final int typeId;
  final String typeName;

  const ShortDramaCategory({
    required this.typeId,
    required this.typeName,
  });

  factory ShortDramaCategory.fromJson(Map<String, dynamic> json) {
    return ShortDramaCategory(
      typeId: json['type_id'] is int
          ? json['type_id']
          : int.tryParse(json['type_id']?.toString() ?? '0') ?? 0,
      typeName: json['type_name']?.toString() ?? '',
    );
  }
}

/// 短剧列表项数据模型
class ShortDrama {
  final int id;
  final String name;
  final String cover;
  final String updateTime;
  final double score;
  final int episodeCount;
  final String description;
  final String author;
  final String backdrop;
  final double voteAverage;

  const ShortDrama({
    required this.id,
    required this.name,
    required this.cover,
    required this.updateTime,
    required this.score,
    required this.episodeCount,
    required this.description,
    required this.author,
    required this.backdrop,
    required this.voteAverage,
  });

  factory ShortDrama.fromJson(Map<String, dynamic> json) {
    return ShortDrama(
      id: json['id'] is int
          ? json['id']
          : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      name: json['name']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      updateTime: json['update_time']?.toString() ?? '',
      score: (json['score'] is num)
          ? (json['score'] as num).toDouble()
          : double.tryParse(json['score']?.toString() ?? '0') ?? 0.0,
      episodeCount: json['episode_count'] is int
          ? json['episode_count']
          : int.tryParse(json['episode_count']?.toString() ?? '0') ?? 0,
      description: json['description']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      backdrop: json['backdrop']?.toString() ?? '',
      voteAverage: (json['vote_average'] is num)
          ? (json['vote_average'] as num).toDouble()
          : double.tryParse(json['vote_average']?.toString() ?? '0') ?? 0.0,
    );
  }
}

/// 短剧列表响应
class ShortDramaListResponse {
  final List<ShortDrama> list;
  final bool hasMore;

  const ShortDramaListResponse({
    required this.list,
    required this.hasMore,
  });

  factory ShortDramaListResponse.fromJson(Map<String, dynamic> json) {
    final listData = json['list'] as List<dynamic>? ?? [];
    return ShortDramaListResponse(
      list: listData
          .map((e) => ShortDrama.fromJson(e as Map<String, dynamic>))
          .toList(),
      hasMore: json['hasMore'] == true,
    );
  }
}

/// 短剧解析结果（播放地址）
class ShortDramaParseResult {
  final int code;
  final String msg;
  final ShortDramaParseData? data;

  const ShortDramaParseResult({
    required this.code,
    required this.msg,
    this.data,
  });

  factory ShortDramaParseResult.fromJson(Map<String, dynamic> json) {
    return ShortDramaParseResult(
      code: json['code'] is int ? json['code'] : -1,
      msg: json['msg']?.toString() ?? '',
      data: json['data'] != null
          ? ShortDramaParseData.fromJson(json['data'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// 短剧解析数据
class ShortDramaParseData {
  final int videoId;
  final String videoName;
  final int currentEpisode;
  final int totalEpisodes;
  final String parsedUrl;
  final String proxyUrl;
  final String cover;
  final String description;

  const ShortDramaParseData({
    required this.videoId,
    required this.videoName,
    required this.currentEpisode,
    required this.totalEpisodes,
    required this.parsedUrl,
    required this.proxyUrl,
    required this.cover,
    required this.description,
  });

  factory ShortDramaParseData.fromJson(Map<String, dynamic> json) {
    final episode = json['episode'] as Map<String, dynamic>?;
    return ShortDramaParseData(
      videoId: json['videoId'] is int
          ? json['videoId']
          : int.tryParse(json['videoId']?.toString() ?? '0') ?? 0,
      videoName: json['videoName']?.toString() ?? '',
      currentEpisode: json['currentEpisode'] is int
          ? json['currentEpisode']
          : int.tryParse(json['currentEpisode']?.toString() ?? '1') ?? 1,
      totalEpisodes: json['totalEpisodes'] is int
          ? json['totalEpisodes']
          : int.tryParse(json['totalEpisodes']?.toString() ?? '1') ?? 1,
      parsedUrl: episode?['parsedUrl']?.toString() ??
          json['parsedUrl']?.toString() ??
          '',
      proxyUrl: episode?['proxyUrl']?.toString() ??
          json['proxyUrl']?.toString() ??
          '',
      cover: json['cover']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
    );
  }
}

/// 短剧详情响应
class ShortDramaDetail {
  final String id;
  final String title;
  final String poster;
  final List<String> episodes;
  final List<String> episodesTitles;
  final String source;
  final String sourceName;
  final String year;
  final String desc;
  final String typeName;
  final String dramaName;

  const ShortDramaDetail({
    required this.id,
    required this.title,
    required this.poster,
    required this.episodes,
    required this.episodesTitles,
    required this.source,
    required this.sourceName,
    required this.year,
    required this.desc,
    required this.typeName,
    required this.dramaName,
  });

  factory ShortDramaDetail.fromJson(Map<String, dynamic> json) {
    return ShortDramaDetail(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: json['poster']?.toString() ?? '',
      episodes: (json['episodes'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      episodesTitles: (json['episodes_titles'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      source: json['source']?.toString() ?? '',
      sourceName: json['source_name']?.toString() ?? '',
      year: json['year']?.toString() ?? '',
      desc: json['desc']?.toString() ?? '',
      typeName: json['type_name']?.toString() ?? '',
      dramaName: json['drama_name']?.toString() ?? '',
    );
  }
}
