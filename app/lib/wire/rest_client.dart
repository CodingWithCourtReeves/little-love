import 'dart:convert';

import 'package:http/http.dart' as http;

import 'frames.dart' show Member;

class AccountRecord {
  AccountRecord({
    required this.username,
    required this.ed25519PubBase64,
    required this.x25519PubBase64,
    required this.createdAt,
  });

  final String username;
  final String ed25519PubBase64;
  final String x25519PubBase64;
  final DateTime createdAt;

  factory AccountRecord.fromJson(Map<String, Object?> json) => AccountRecord(
    username: json['username']! as String,
    ed25519PubBase64: json['ed25519_pub']! as String,
    x25519PubBase64: json['x25519_pub']! as String,
    createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
  );
}

class PostAccountReply {
  PostAccountReply({required this.username, required this.createdAt});
  final String username;
  final DateTime createdAt;
}

class UsernameTakenException implements Exception {
  const UsernameTakenException();
  @override
  String toString() => 'username already taken';
}

class InvalidUsernameException implements Exception {
  const InvalidUsernameException();
  @override
  String toString() => 'invalid username format';
}

class RestHttpException implements Exception {
  RestHttpException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RestClient {
  RestClient({required Uri baseUri, http.Client? httpClient})
    : _base = baseUri,
      _http = httpClient ?? http.Client();

  final Uri _base;
  final http.Client _http;

  Uri _resolve(String path) {
    final basePath = _base.path.endsWith('/')
        ? _base.path.substring(0, _base.path.length - 1)
        : _base.path;
    final tail = path.startsWith('/') ? path : '/$path';
    return _base.replace(path: '$basePath$tail');
  }

  Future<PostAccountReply> postAccount({
    required String username,
    required String ed25519PubBase64,
    required String x25519PubBase64,
  }) async {
    final res = await _http.post(
      _resolve('/accounts'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'username': username,
        'ed25519_pub': ed25519PubBase64,
        'x25519_pub': x25519PubBase64,
      }),
    );
    if (res.statusCode == 201) {
      final j = jsonDecode(res.body) as Map<String, Object?>;
      return PostAccountReply(
        username: j['username']! as String,
        createdAt: DateTime.parse(j['created_at']! as String).toUtc(),
      );
    }
    if (res.statusCode == 409) throw const UsernameTakenException();
    if (res.statusCode == 400) throw const InvalidUsernameException();
    throw RestHttpException('POST /accounts failed: HTTP ${res.statusCode}');
  }

  Future<AccountRecord?> getAccountByUsername(String username) async {
    final res = await _http.get(_resolve('/accounts/by-username/$username'));
    if (res.statusCode == 200) {
      return AccountRecord.fromJson(
        jsonDecode(res.body) as Map<String, Object?>,
      );
    }
    if (res.statusCode == 404) return null;
    throw RestHttpException(
      'GET /accounts/by-username failed: HTTP ${res.statusCode}',
    );
  }

  Future<InvitePreviewResponse> previewInvite(String code) async {
    final res = await _http.post(_resolve('/invites/$code/preview'));
    if (res.statusCode == 200) {
      final j = jsonDecode(res.body) as Map<String, Object?>;
      return InvitePreviewResponse.fromJson(j);
    }
    if (res.statusCode == 404) throw const InviteNotFoundException();
    if (res.statusCode == 410) throw const InviteGoneException();
    throw RestHttpException(
      'POST /invites/$code/preview failed: HTTP ${res.statusCode}',
    );
  }
}

class InvitePreviewResponse {
  InvitePreviewResponse({
    required this.roomId,
    required this.name,
    required this.members,
    required this.expiresAt,
  });

  final String roomId;
  final String name;
  final List<Member> members;
  final DateTime expiresAt;

  factory InvitePreviewResponse.fromJson(Map<String, Object?> json) =>
      InvitePreviewResponse(
        roomId: json['room_id']! as String,
        name: (json['name'] as String?) ?? '',
        members: (json['members']! as List<Object?>)
            .map((m) => Member.fromJson(m! as Map<String, Object?>))
            .toList(),
        expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
      );
}

class InviteNotFoundException implements Exception {
  const InviteNotFoundException();
  @override
  String toString() => 'invite not found';
}

class InviteGoneException implements Exception {
  const InviteGoneException();
  @override
  String toString() => 'invite expired or consumed';
}
