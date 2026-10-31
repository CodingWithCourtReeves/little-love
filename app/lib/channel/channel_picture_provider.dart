import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_download.dart';
import '../conversation/message_store.dart';
import '../diagnostics/crash_reporting.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'channel_picture.dart';

/// The room's current channel picture: the latest non-failed `channel_update`
/// that carries a picture, ordered by `ts` then `id` so arrival order does not
/// matter. Null when there is none or the latest removed the picture. An
/// [UnknownPicture] is returned as-is (the tile renders it as the letter).
final currentChannelPictureProvider = Provider.family<ChannelPicture?, String>((
  ref,
  roomId,
) {
  Msg? latest;
  for (final m in ref.watch(messageStoreProvider(roomId))) {
    if (m.channelUpdate?.picture == null || m.sendStatus == SendStatus.failed) {
      continue;
    }
    if (latest == null) {
      latest = m;
      continue;
    }
    final c = m.ts.compareTo(latest.ts);
    if (c > 0 || (c == 0 && m.id.compareTo(latest.id) > 0)) latest = m;
  }
  final picture = latest?.channelUpdate?.picture;
  return picture is NoPicture ? null : picture;
});

/// The decrypted photo file for the room's current picture, or null when the
/// picture is not a photo, there is no live connection, or the fetch failed.
final channelPhotoFileProvider = FutureProvider.family<File?, String>((
  ref,
  roomId,
) async {
  final picture = ref.watch(currentChannelPictureProvider(roomId));
  if (picture is! PhotoPicture) return null;
  final conn = ref.read(liveConnectionProvider).asData?.value;
  if (conn == null) return null;
  try {
    return await fetchAndDecrypt(conn: conn, descriptor: picture.descriptor);
  } catch (e, st) {
    reportFault(e, st, context: 'channel_picture_fetch');
    return null;
  }
});
