class Msg {
  Msg({
    required this.id,
    required this.from,
    required this.to,
    required this.body,
    required this.ts,
    this.replayed = false,
  });

  final String id;
  final String from;
  final String to;

  /// Plain text Day-1a/b; a base64 ciphertext envelope Day-1c.
  /// At the Dart layer in Day-1a we treat it as opaque string.
  final String body;
  final DateTime ts;
  final bool replayed;

  factory Msg.fromJson(Map<String, Object?> json) {
    return Msg(
      id: json['id'] as String,
      from: json['from'] as String,
      to: json['to'] as String,
      body: json['body'] as String,
      ts: DateTime.parse(json['ts'] as String).toUtc(),
      replayed: (json['replayed'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() {
    final m = <String, Object?>{
      'type': 'msg',
      'id': id,
      'from': from,
      'to': to,
      'body': body,
      'ts': ts.toUtc().toIso8601String(),
    };
    if (replayed) m['replayed'] = true;
    return m;
  }
}

class Hello {
  Hello({required this.since});
  final DateTime since;

  Map<String, Object?> toJson() => {
    'type': 'hello',
    'since': since.toUtc().toIso8601String(),
  };
}
