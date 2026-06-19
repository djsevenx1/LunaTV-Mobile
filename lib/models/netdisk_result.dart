/// 网盘搜索结果模型
class NetdiskResult {
  final String title;
  final String url;
  final String source;
  final String size;
  final String date;

  NetdiskResult({
    required this.title,
    required this.url,
    required this.source,
    required this.size,
    required this.date,
  });

  factory NetdiskResult.fromJson(Map<String, dynamic> json) {
    return NetdiskResult(
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      source: json['source'] as String? ?? '',
      size: json['size'] as String? ?? '',
      date: json['date'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
      'source': source,
      'size': size,
      'date': date,
    };
  }
}
