import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../inbox/room.dart';
import '../theme/app_palette.dart';
import 'channel_picture.dart';
import 'channel_picture_provider.dart';

/// A channel's picture as a rounded square: a photo, a symbol on its swatch,
/// or the first letter of the name on a colour derived from [colorSeed].
class ChannelPictureView extends StatelessWidget {
  const ChannelPictureView({
    super.key,
    required this.name,
    required this.colorSeed,
    this.picture,
    this.photo,
    this.size = 52,
  });

  final String name;
  final String colorSeed;
  final ChannelPicture? picture;
  final ImageProvider? photo;
  final double size;

  /// The first-letter tile on the colour derived from [colorSeed]; also the
  /// fallback when a photo can't be decoded.
  Widget _letterTile(BuildContext context) {
    final sw =
        context.palette.channelSwatches[channelColorFor(colorSeed).index];
    return ColoredBox(
      color: sw.tint,
      child: name.isEmpty
          ? null
          : Center(
              child: Text(
                name.characters.first.toUpperCase(),
                style: TextStyle(
                  fontSize: size * 22 / 52,
                  fontWeight: FontWeight.w600,
                  color: sw.ink,
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final swatches = context.palette.channelSwatches;
    final Widget content;
    final p = picture;
    if (photo != null) {
      content = Image(
        image: ResizeImage(
          photo!,
          width: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.cover,
        width: size,
        height: size,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => _letterTile(context),
      );
    } else if (p is SymbolPicture) {
      final sw = swatches[p.color.index];
      content = ColoredBox(
        color: sw.tint,
        child: Center(
          child: SvgPicture.asset(
            'assets/channel_symbols/${p.symbol.name}.svg',
            width: size / 2,
            height: size / 2,
            colorFilter: ColorFilter.mode(sw.ink, BlendMode.srcIn),
          ),
        ),
      );
    } else {
      content = _letterTile(context);
    }
    return Semantics(
      label: '$name channel picture',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        key: Key('channel-picture-$colorSeed'),
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 14 / 52),
          child: content,
        ),
      ),
    );
  }
}

/// The inline thumbnail decoded once per base64 string, so every rebuild hands
/// the image cache the same bytes (a fresh `Uint8List` per build would be a
/// new cache key and re-decode). Null for an empty or malformed string: the
/// descriptor comes from the partner, so it is untrusted.
final _thumbBytesProvider = Provider.family<Uint8List?, String>((ref, b64) {
  if (b64.isEmpty) return null;
  try {
    return base64Decode(b64);
  } on FormatException {
    return null;
  }
});

/// The photo to draw for [roomId]'s current picture: the downloaded file once
/// it is on disk, else the inline thumbnail, else null (not a photo picture, or
/// nothing decodable yet). One path for the tile and for the picker sheet's
/// "current" preview.
ImageProvider? channelPhotoFor(WidgetRef ref, String roomId) {
  final picture = ref.watch(currentChannelPictureProvider(roomId));
  if (picture is! PhotoPicture) return null;
  final file = ref.watch(channelPhotoFileProvider(roomId)).asData?.value;
  if (file != null) return FileImage(file);
  final thumb = ref.watch(_thumbBytesProvider(picture.descriptor.thumbB64));
  return thumb == null ? null : MemoryImage(thumb);
}

/// [ChannelPictureView] for a room, fed by the room's current picture.
class ChannelTile extends ConsumerWidget {
  const ChannelTile({
    super.key,
    required this.room,
    required this.selfUsername,
    this.size = 52,
  });

  final Room room;
  final String selfUsername;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ChannelPictureView(
      name: room.displayName(selfUsername),
      colorSeed: room.roomId,
      picture: ref.watch(currentChannelPictureProvider(room.roomId)),
      photo: channelPhotoFor(ref, room.roomId),
      size: size,
    );
  }
}
