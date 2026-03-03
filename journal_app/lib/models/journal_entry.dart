class JournalEntry {
  final String id;
  final String authorId;
  final String authorUsername;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String content;

  const JournalEntry({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.createdAt,
    required this.updatedAt,
    required this.content,
  });

  JournalEntry copyWith({String? content}) {
    return JournalEntry(
      id: id,
      authorId: authorId,
      authorUsername: authorUsername,
      createdAt: createdAt,
      updatedAt: updatedAt,
      content: content ?? this.content,
    );
  }

  factory JournalEntry.fromJson(Map<String, dynamic> json) {
    return JournalEntry(
      id: json['id'] as String,
      authorId: json['author_id'] as String,
      authorUsername: json['author_username'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      content: json['content'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'author_id': authorId,
        'author_username': authorUsername,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'content': content,
      };
}
