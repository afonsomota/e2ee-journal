// models/user.dart
//
// [Step1-2] Only id and username are used.
// [Step4+]  publicKey is added — the server holds this openly.
//           encryptedPrivateKey is the private key encrypted with the
//           password-derived key; server stores it but cannot read it.

class User {
  final String id;
  final String username;

  // [Step4+] Base64-encoded X25519 public key.
  // Stored on and distributed by the server openly.
  final String? publicKey;

  // [Step4+] Base64-encoded private key, encrypted with the Argon2-derived
  // symmetric key.  Server stores it; only the user can decrypt it.
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
