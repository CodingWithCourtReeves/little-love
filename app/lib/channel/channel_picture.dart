import 'dart:typed_data';

import '../attachment/attachment_descriptor.dart';

/// Glyphs a channel can use as its picture. Wire name is [Enum.name].
enum ChannelSymbol {
  heart,
  house,
  plane,
  paw,
  utensils,
  music,
  film,
  star,
  gift,
  sun,
  leaf,
  moon,
}

/// Tile colours a channel can use. Wire name is [Enum.name].
enum ChannelColor { rose, clay, sand, sage, sky, lavender }

/// Deterministic colour for a seed (same hash as the avatar fallback).
ChannelColor channelColorFor(String seed) {
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return ChannelColor.values[h % ChannelColor.values.length];
}

/// A channel's picture as carried in an encrypted `channel_update`.
sealed class ChannelPicture {
  const ChannelPicture();

  Map<String, Object?> toJson();

  /// Throws [FormatException] or [TypeError] on a malformed known type;
  /// an unrecognised `type`, symbol or colour yields [UnknownPicture].
  static ChannelPicture fromJson(Map<String, Object?> j) {
    switch (j['type']) {
      case 'photo':
        return PhotoPicture(AttachmentDescriptor.fromJson(j));
      case 'none':
        return const NoPicture();
      case 'symbol':
        final symbol = ChannelSymbol.values.asNameMap()[j['symbol']];
        final color = ChannelColor.values.asNameMap()[j['color']];
        if (symbol == null || color == null) return UnknownPicture(j);
        return SymbolPicture(symbol, color);
    }
    return UnknownPicture(j);
  }
}

class PhotoPicture extends ChannelPicture {
  const PhotoPicture(this.descriptor);
  final AttachmentDescriptor descriptor;

  @override
  Map<String, Object?> toJson() => {'type': 'photo', ...descriptor.toJson()};
}

class SymbolPicture extends ChannelPicture {
  const SymbolPicture(this.symbol, this.color);
  final ChannelSymbol symbol;
  final ChannelColor color;

  @override
  Map<String, Object?> toJson() => {
    'type': 'symbol',
    'symbol': symbol.name,
    'color': color.name,
  };
}

class NoPicture extends ChannelPicture {
  const NoPicture();

  @override
  Map<String, Object?> toJson() => {'type': 'none'};
}

/// A picture from a newer build that this one can't render (renders as the
/// letter). Keeps the original JSON so re-persisting it never crashes.
class UnknownPicture extends ChannelPicture {
  const UnknownPicture(this.raw);
  final Map<String, Object?> raw;

  @override
  Map<String, Object?> toJson() => raw;
}

/// What the user picked in the picture editor, before it is encoded.
sealed class ChannelPictureChoice {
  const ChannelPictureChoice();
}

class ChoosePhoto extends ChannelPictureChoice {
  const ChoosePhoto(this.squaredJpeg);
  final Uint8List squaredJpeg;
}

class ChooseSymbol extends ChannelPictureChoice {
  const ChooseSymbol(this.symbol, this.color);
  final ChannelSymbol symbol;
  final ChannelColor color;
}

class ChooseNone extends ChannelPictureChoice {
  const ChooseNone();
}
