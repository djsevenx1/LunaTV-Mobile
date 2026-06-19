/// 短剧数据模型
class ShortDrama {
  final String id;
  final String title;
  final String cover;
  final String description;
  final int episodeCount;
  final String category;
  final String source;
  final List<ShortDramaEpisode> episodes;

  const ShortDrama({
    required this.id,
    required this.title,
    required this.cover,
    required this.description,
    required this.episodeCount,
    required this.category,
    required this.source,
    required this.episodes,
  });

  factory ShortDrama.fromJson(Map<String, dynamic> json) {
    return ShortDrama(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      episodeCount: json['episode_count'] is int
          ? json['episode_count']
          : int.tryParse(json['episode_count']?.toString() ?? '0') ?? 0,
      category: json['category']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      episodes: (json['episodes'] as List<dynamic>? ?? [])
          .map((e) =>
              ShortDramaEpisode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'cover': cover,
      'description': description,
      'episode_count': episodeCount,
      'category': category,
      'source': source,
      'episodes': episodes.map((e) => e.toJson()).toList(),
    };
  }
}

/// 短剧单集数据模型
class ShortDramaEpisode {
  final String id;
  final String title;
  final String url;

  const ShortDramaEpisode({
    required this.id,
    required this.title,
    required this.url,
  });

  factory ShortDramaEpisode.fromJson(Map<String, dynamic> json) {
    return ShortDramaEpisode(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'url': url,
    };
  }
}
