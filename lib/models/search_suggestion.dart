/// 搜索建议模型
class SearchSuggestion {
  final String text;
  final String type;
  final double score;

  SearchSuggestion({
    required this.text,
    required this.type,
    required this.score,
  });

  factory SearchSuggestion.fromJson(Map<String, dynamic> json) {
    return SearchSuggestion(
      text: json['text'] as String,
      type: json['type'] as String,
      score: (json['score'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'type': type,
      'score': score,
    };
  }
}
