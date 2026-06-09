sealed class ServerFrame {
  const ServerFrame();

  factory ServerFrame.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    switch (kind) {
      case 'Challenge':
        return ChallengeFrame(nonceBase64: json['nonce']! as String);
      case 'Authenticated':
        return const AuthenticatedFrame();
      case 'Error':
        return ErrorFrame(
          code: json['code']! as String,
          message: (json['message'] as String?) ?? '',
        );
      default:
        throw FormatException('unknown server frame kind: $kind');
    }
  }
}

class ChallengeFrame extends ServerFrame {
  const ChallengeFrame({required this.nonceBase64});
  final String nonceBase64;
}

class AuthenticatedFrame extends ServerFrame {
  const AuthenticatedFrame();
}

class ErrorFrame extends ServerFrame {
  const ErrorFrame({required this.code, required this.message});
  final String code;
  final String message;
}

class IdentifyFrame {
  IdentifyFrame({required this.username, required this.signatureBase64});
  final String username;
  final String signatureBase64;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'Identify',
    'username': username,
    'signature': signatureBase64,
  };
}
