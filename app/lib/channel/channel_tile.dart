import 'dart:convert';

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
      final sw = swatches[channelColorFor(colorSeed).index];
      content = ColoredBox(
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
    final picture = ref.watch(currentChannelPictureProvider(room.roomId));
    ImageProvider? photo;
    if (picture is PhotoPicture) {
      final file = ref
          .watch(channelPhotoFileProvider(room.roomId))
          .asData
          ?.value;
      photo = file != null
          ? FileImage(file)
          : MemoryImage(base64Decode(picture.descriptor.thumbB64));
    }
    return ChannelPictureView(
      name: room.displayName(selfUsername),
      colorSeed: room.roomId,
      picture: picture,
      photo: photo,
      size: size,
    );
  }
}
