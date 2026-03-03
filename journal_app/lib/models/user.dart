// models/user.dart
//
// [Step 1-2] Only id and username.
// [Step 4+]  publicKey and encryptedPrivateKey are added.

class User {
  final String id;
  final String username;

  // [Step 4+] Base64-encoded X25519 public key.
  final String? publicKey;

  // [Step 4+] Base64-encoded private key, encrypted with the Argon2-derived key.
  final String? encryptedPrivateKey;

  const User({
    required this.id,
    required this.username,
    this.publicKey,
    this.encryptedPrivateKey,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      username: json['username'] as String,
      publicKey: json['public_key'] as String?,
      encryptedPrivateKey: json['encrypted_private_key'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        if (publicKey != null) 'public_key': publicKey,
        if (encryptedPrivateKey != null)
          'encrypted_private_key': encryptedPrivateKey,
      };
}
