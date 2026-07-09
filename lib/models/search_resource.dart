/// 搜索资源模型
class SearchResource {
  final String key;
  final String name;
  final String api;
  final String detail;
  final String from;
  final bool disabled;

  SearchResource({
    required this.key,
    required this.name,
    required this.api,
    required this.detail,
    required this.from,
    required this.disabled,
  });

  factory SearchResource.fromJson(Map<String, dynamic> json) {
    return SearchResource(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      api: json['api'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      from: json['from'] as String? ?? '',
      disabled: json['disabled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'api': api,
      'detail': detail,
      'from': from,
      'disabled': disabled,
    };
  }
}
