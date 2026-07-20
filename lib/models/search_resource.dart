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
      // v2.4.4: api 字段 trim, 去除前后空格. 之前没 trim,
      //   如果用户配置的 api 前后有空格, 拼出的 URL 会破损.
      //   详见 source_browser_service.dart _buildUrl 注释.
      api: (json['api'] as String? ?? '').trim(),
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
