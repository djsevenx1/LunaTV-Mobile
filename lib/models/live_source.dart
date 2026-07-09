/// 直播源模型
class LiveSource {
  final String key;
  final String name;
  final String url;
  final String ua;
  final String epg;
  final String from;
  final bool disabled;

  LiveSource({
    required this.key,
    required this.name,
    required this.url,
    required this.ua,
    required this.epg,
    required this.from,
    required this.disabled,
  });

  factory LiveSource.fromJson(Map<String, dynamic> json) {
    return LiveSource(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      ua: json['ua'] as String? ?? '',
      epg: json['epg'] as String? ?? '',
      from: json['from'] as String? ?? '',
      disabled: json['disabled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'url': url,
      'ua': ua,
      'epg': epg,
      'from': from,
      'disabled': disabled,
    };
  }
}
