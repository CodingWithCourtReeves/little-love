import 'package:flutter/foundation.dart';

import '../wire/frames.dart';

/// A v0.3 room: multi-member, optionally named. Members include the
/// authenticated user, zero or one human partner, and zero or more
/// familiars (`isBot`).
@immutable
class Room {
  const Room({
    required this.roomId,
    required this.name,
    required this.members,
    required this.createdAt,
  });

  final String roomId;
  final String name;
  final List<Member> members;
  final DateTime createdAt;

  /// Spec §7.1 derived display name. When `name` is non-empty, returns it
  /// verbatim. Otherwise concatenates other members: humans (Title-Case)
  /// then bots (label-only, alpha-sorted within each group), joined with
  /// " + ". Self is never named.
  String displayName(String selfUsername) {
    if (name.isNotEmpty) return name;
    final others = members.where((m) => m.username != selfUsername);
    final humans = others.where((m) => !m.isBot).map(_capitalize).toList()
      ..sort();
    final bots = others.where((m) => m.isBot).map(_botLabel).toList()..sort();
    return [...humans, ...bots].join(' + ');
  }

  /// Sidebar shape (spec §7.3): "COUPLES" rooms have exactly one other
  /// human and no bots. Everything else is "FAMILIARS".
  RoomShape shape(String selfUsername) {
    final others = members.where((m) => m.username != selfUsername);
    final humans = others.where((m) => !m.isBot).length;
    final bots = others.where((m) => m.isBot).length;
    if (humans == 1 && bots == 0) return RoomShape.couplesOnly;
    return RoomShape.familiars;
  }

  Member? memberByPubkey(String x25519PubBase64) {
    for (final m in members) {
      if (m.x25519PubBase64 == x25519PubBase64) return m;
    }
    return null;
  }

  Member? memberByUsername(String username) {
    for (final m in members) {
      if (m.username == username) return m;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Room &&
          other.roomId == roomId &&
          other.name == name &&
          other.createdAt == createdAt &&
          listEquals(
            other.members.map((m) => m.username).toList(),
            members.map((m) => m.username).toList(),
          ));

  @override
  int get hashCode => Object.hash(roomId, name, createdAt, members.length);

  @override
  String toString() =>
      'Room(roomId: $roomId, name: $name, members: ${members.length})';
}

enum RoomShape { couplesOnly, familiars }

String _capitalize(Member m) => m.username.isEmpty
    ? ''
    : m.username[0].toUpperCase() + m.username.substring(1);

/// Strip the `<owner>-` prefix from a familiar username and Title-Case the
/// remaining label. Bot username convention is `<owner>-<label>`.
String _botLabel(Member b) {
  final dash = b.username.indexOf('-');
  final label = dash >= 0 ? b.username.substring(dash + 1) : b.username;
  if (label.isEmpty) return label;
  return label[0].toUpperCase() + label.substring(1);
}
