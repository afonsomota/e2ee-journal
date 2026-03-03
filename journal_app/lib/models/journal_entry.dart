// ─────────────────────────────────────────────────────────────────────────────
// models/journal_entry.dart
//
// Domain model.  The `content` field holds PLAINTEXT after decryption on the
// client; it is NEVER sent to the server in this form from Step 3 onward.
//
// [Step1]  content is sent & received as plaintext.
// [Step3+] content is the decrypted result; ciphertext lives in encryptedBlob.
// [Step5+] encryptedContentKey holds the per-entry symmetric key, itself
//          encrypted with the author's (or recipient's) public key.
// ─────────────────────────────────────────────────────────────────────────────

class JournalEntry {
  final String id;
  final String authorId;
  final String authorUsername;
  final DateTime createdAt;
  final DateTime updatedAt;

  // ── Step 1 & 2 ──────────────────────────────────────────────────────────────
  // Raw content.  Used only in Steps 1 and 2; set by decryption in Step 3+.
  final String content;

  // ── Step 3+ ─────────────────────────────────────────────────────────────────
  // Base64-encoded ciphertext of the journal entry body.
  // Format: nonce (24 bytes) || ciphertext — produced by libsodium secretbox.
  final String? encryptedBlob;

  // ── Step 5+ ─────────────────────────────────────────────────────────────────
  // Base64-encoded content key, itself encrypted with the entry owner's public
  // key via crypto_box_seal.  Decrypting this gives the 32-byte key used to
  // decrypt encryptedBlob.
  final String? encryptedContentKey;

  // ── Step 6 ──────────────────────────────────────────────────────────────────
  // Present when this entry was shared TO the current user.
  // Contains the content key encrypted with the current user's public key.
  final String? sharedEncryptedContentKey;

  // Usernames this entry has been shared with (populated from the share list).
  final List<String> sharedWith;

  const JournalEntry({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.createdAt,
    required this.updatedAt,
    required this.content,
    this.encryptedBlob,
    this.encryptedContentKey,
    this.sharedEncryptedContentKey,
    this.sharedWith = const [],
  });

  JournalEntry copyWith({
    String? content,
    String? encryptedBlob,
    String? encryptedContentKey,
    String? sharedEncryptedContentKey,
    List<String>? sharedWith,
  }) {
    return JournalEntry(
      id: id,
      authorId: authorId,
      authorUsername: authorUsername,
      createdAt: createdAt,
      updatedAt: updatedAt,
      content: content ?? this.content,
      encryptedBlob: encryptedBlob ?? this.encryptedBlob,
      encryptedContentKey: encryptedContentKey ?? this.encryptedContentKey,
      sharedEncryptedContentKey:
          sharedEncryptedContentKey ?? this.sharedEncryptedContentKey,
      sharedWith: sharedWith ?? this.sharedWith,
    );
  }

  // ── JSON serialization ───────────────────────────────────────────────────────

  factory JournalEntry.fromJson(Map<String, dynamic> json) {
    return JournalEntry(
      id: json['id'] as String,
      authorId: json['author_id'] as String,
      authorUsername: json['author_username'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      // Step 1/2: plaintext content (empty string if not present)
      content: json['content'] as String? ?? '',
      // Step 3+: encrypted blob
      encryptedBlob: json['encrypted_blob'] as String?,
      // Step 5+: content key encrypted for the author
      encryptedContentKey: json['encrypted_content_key'] as String?,
      // Step 6: content key encrypted for the current viewer (sharing)
      sharedEncryptedContentKey:
          json['shared_encrypted_content_key'] as String?,
      sharedWith: (json['shared_with'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'author_id': authorId,
      'author_username': authorUsername,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'content': content,
      if (encryptedBlob != null) 'encrypted_blob': encryptedBlob,
      if (encryptedContentKey != null)
        'encrypted_content_key': encryptedContentKey,
      if (sharedEncryptedContentKey != null)
        'shared_encrypted_content_key': sharedEncryptedContentKey,
      'shared_with': sharedWith,
    };
  }
}
