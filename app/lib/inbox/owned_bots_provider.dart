import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/frames.dart';

/// Familiars the authenticated user owns (sourced from `RoomsFrame.ownedBots`).
/// Drives the Create-Chat picker so it can surface familiars not yet in any
/// room.
class OwnedBotsNotifier extends Notifier<List<Member>> {
  @override
  List<Member> build() => const [];

  void set(List<Member> bots) => state = List.unmodifiable(bots);
}

final ownedBotsProvider = NotifierProvider<OwnedBotsNotifier, List<Member>>(
  OwnedBotsNotifier.new,
);
