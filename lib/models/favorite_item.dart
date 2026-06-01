class FavoriteItem {
  final String id;
  final String source; // 来源标识
  final String title;
  final String sourceName;
  final String year;
  final String cover;
  final int totalEpisodes;
  final int saveTime;
  final String origin; // 添加origin字段

  FavoriteItem({
    required this.id,
    required this.source,
    required this.title,
    required this.sourceName,
    required this.year,
    required this.cover,
    required this.totalEpisodes,
    required this.saveTime,
    required this.origin,
  });

  factory FavoriteItem.fromJson(String key, Map<String, dynamic> json) {
    // 从key中分离source和id，格式为 "source+id"
    final parts = key.split('+');
    final source = parts.length > 1 ? parts[0] : '';
    final id = parts.length > 1 ? parts[1] : key;
    
    return FavoriteItem(
      id: id,
      source: source,
      title: json['title'] ?? '',
      sourceName: json['source_name'] ?? '',
      year: json['year'] ?? '',
      cover: json['cover'] ?? '',
      totalEpisodes: json['total_episodes'] ?? 0,
      saveTime: json['save_time'] ?? 0,
      origin: json['origin'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'source_name': sourceName,
      'year': year,
      'cover': cover,
      'total_episodes': totalEpisodes,
      'save_time': saveTime,
      'origin': origin,
    };
  }
}
