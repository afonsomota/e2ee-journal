class EmotionResult {
  final String emotion;
  final double confidence;

  const EmotionResult({required this.emotion, required this.confidence});

  factory EmotionResult.fromJson(Map<String, dynamic> json) {
    return EmotionResult(
      emotion: json['emotion'] as String,
      confidence: (json['confidence'] as num).toDouble(),
    );
  }
}
