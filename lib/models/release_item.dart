/// 发布日历数据模型
class ReleaseItem {
  final String id;
  final String title;
  final String cover;
  final String releaseDate; // 发布日期
  final String type; // movie/tv/anime
  final String region; // 地区
  final String description;

  ReleaseItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.releaseDate,
    required this.type,
    required this.region,
    required this.description,
  });

  /// 从JSON创建ReleaseItem
  factory ReleaseItem.fromJson(Map<String, dynamic> json) {
    return ReleaseItem(
      id: json['id']?.toString() ?? '',
      title: json['title'] ?? '',
      cover: json['cover'] ?? '',
      releaseDate: json['release_date'] ?? '',
      type: json['type'] ?? '',
      region: json['region'] ?? '',
      description: json['description'] ?? '',
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'cover': cover,
      'release_date': releaseDate,
      'type': type,
      'region': region,
      'description': description,
    };
  }

  /// 获取类型显示名称
  String get typeDisplayName {
    switch (type) {
      case 'movie':
        return '电影';
      case 'tv':
        return '电视剧';
      case 'anime':
        return '动漫';
      default:
        return type;
    }
  }
}
