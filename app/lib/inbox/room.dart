import 'package:flutter/foundation.dart';

import '../wire/frames.dart';

/// A room: multi-member, optionally named. Members include the
/// authenticated user and zero or one human partner.
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
  /// verbatim. Otherwise concatenates the other members (Title-Case,
  /// alpha-sorted), joined with " + ". Self is never named.
  String displayName(String selfUsername) {
    if (name.isNotEmpty) return name;
    final others = members.where((m) => m.username != selfUsername);
    final humans = others.map(_capitalize).toList()..sort();
    final derived = humans.join(' + ');
    // A freshly created room you're the only member of (e.g. a pending-invite
    // room before the partner joins) has no others to derive from. Never
    // render a blank label.
    return derived.isEmpty ? 'New chat' : derived;
  }

  /// Sidebar shape (spec §7.3): two buckets.
  ///
  /// - `partner`  — 1:1 unnamed DM with the human partner.
  /// - `chat`     — anything else: 3+ members or named rooms.
  ///
  /// A `name` is treated as the user's signal that this is a topical
  /// chat room rather than the default DM, so any named room is a chat
  /// regardless of member count.
  RoomShape shape(String selfUsername) {
    final others = members.where((m) => m.username != selfUsername).toList();
    if (name.isNotEmpty) return RoomShape.chat;
    if (others.length == 1) return RoomShape.partner;
    return RoomShape.chat;
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

enum RoomShape { partner, chat }

String _capitalize(Member m) => m.username.isEmpty
    ? ''
    : m.username[0].toUpperCase() + m.username.substring(1);
