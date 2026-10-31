import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../attachment/attachment_descriptor.dart';
import '../attachment/attachment_download.dart';
import '../attachment/square_image.dart';
import '../conversation/shared_media_page.dart';
import '../diagnostics/crash_reporting.dart';
import '../inbox/room.dart';
import '../theme/app_palette.dart';
import '../wire/live_connection.dart';
import 'channel_picture.dart';
import 'channel_picture_sheet_parts.dart';
import 'channel_tile.dart';

/// Reads the raw bytes of a photo the user picks from [source]; null when they
/// cancel. Injectable because the platform picker can't run in widget tests.
typedef PhotoSource = Future<Uint8List?> Function(ImageSource source);

/// Centre-crops [bytes] to a square JPEG. Throws [FormatException] if the
/// bytes aren't an image. Injectable so tests can skip the isolate.
typedef Squarer = Future<Uint8List> Function(Uint8List bytes);

Future<Uint8List?> _pickWithImagePicker(ImageSource source) async {
  final picked = await ImagePicker().pickImage(
    source: source,
    imageQuality: 100,
  );
  return picked?.readAsBytes();
}

Uint8List _square(Uint8List bytes) => squareJpeg(bytes);

Future<Uint8List> _squareInIsolate(Uint8List bytes) => compute(_square, bytes);

/// Shows the channel picture sheet. Returns what the user chose, or null on
/// Cancel or dismiss. Sends nothing. A null [room] (the create sheet) hides
/// "Pick from this chat's photos".
Future<ChannelPictureChoice?> showChannelPictureSheet(
  BuildContext context, {
  required String name,
  required String colorSeed,
  ChannelPicture? current,
  ImageProvider? currentPhoto,
  Room? room,
  @visibleForTesting PhotoSource? photoSource,
  @visibleForTesting Squarer? squarer,
}) {
  final p = context.palette;
  return showModalBottomSheet<ChannelPictureChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: p.bgCanvas,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ChannelPictureSheet(
      name: name,
      colorSeed: colorSeed,
      current: current,
      currentPhoto: currentPhoto,
      room: room,
      photoSource: photoSource ?? _pickWithImagePicker,
      squarer: squarer ?? _squareInIsolate,
    ),
  );
}

class ChannelPictureSheet extends ConsumerStatefulWidget {
  const ChannelPictureSheet({
    super.key,
    required this.name,
    required this.colorSeed,
    required this.photoSource,
    required this.squarer,
    this.current,
    this.currentPhoto,
    this.room,
  });

  final String name;
  final String colorSeed;
  final ChannelPicture? current;
  final ImageProvider? currentPhoto;
  final Room? room;
  final PhotoSource photoSource;
  final Squarer squarer;

  @override
  ConsumerState<ChannelPictureSheet> createState() =>
      _ChannelPictureSheetState();
}

class _ChannelPictureSheetState extends ConsumerState<ChannelPictureSheet> {
  late bool _symbolTab = widget.current is! PhotoPicture;
  late ChannelSymbol _symbol = switch (widget.current) {
    SymbolPicture(:final symbol) => symbol,
    _ => ChannelSymbol.heart,
  };
  late ChannelColor _color = switch (widget.current) {
    SymbolPicture(:final color) => color,
    _ => channelColorFor(widget.colorSeed),
  };

  /// A freshly picked, already squared photo; null until the user picks one.
  Uint8List? _photo;
  bool _busy = false;

  /// The sheet hosts its own messenger so the toast shows above the sheet
  /// rather than behind it.
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  void _toast() {
    _messenger.currentState?.showSnackBar(
      const SnackBar(content: Text("Couldn't use that photo.")),
    );
  }

  /// Squares [bytes] and makes them the pending photo. Undecodable bytes show
  /// the toast and change nothing.
  Future<void> _useBytes(Uint8List bytes) async {
    try {
      final squared = await widget.squarer(bytes);
      if (!mounted) return;
      setState(() => _photo = squared);
    } on FormatException {
      if (mounted) _toast();
    } catch (e, st) {
      reportFault(e, st, context: 'channel_picture_pick');
      if (mounted) _toast();
    }
  }

  Future<void> _pickFrom(ImageSource source) async {
    if (_busy) return;
    _busy = true;
    try {
      final bytes = await widget.photoSource(source);
      if (!mounted || bytes == null) return;
      await _useBytes(bytes);
    } catch (e, st) {
      reportFault(e, st, context: 'channel_picture_pick');
      if (mounted) _toast();
    } finally {
      _busy = false;
    }
  }

  Future<void> _pickFromChat() async {
    final room = widget.room;
    if (room == null || _busy) return;
    final descriptor = await Navigator.of(
      context,
    ).push<AttachmentDescriptor>(SharedMediaPage.pickPhotoRoute(room: room));
    if (!mounted || descriptor == null) return;
    _busy = true;
    try {
      final conn = ref.read(liveConnectionProvider).asData?.value;
      if (conn == null) throw StateError('no connection');
      final file = await fetchAndDecrypt(conn: conn, descriptor: descriptor);
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await _useBytes(bytes);
    } catch (e, st) {
      reportFault(e, st, context: 'channel_picture_pick');
      if (mounted) _toast();
    } finally {
      _busy = false;
    }
  }

  ChannelPictureChoice? get _choice {
    if (_symbolTab) return ChooseSymbol(_symbol, _color);
    final photo = _photo;
    return photo == null ? null : ChoosePhoto(photo);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final current = widget.current;
    final ChannelPicture? previewPicture;
    final ImageProvider? previewPhoto;
    if (_symbolTab) {
      previewPicture = SymbolPicture(_symbol, _color);
      previewPhoto = null;
    } else if (_photo != null) {
      previewPicture = null;
      previewPhoto = MemoryImage(_photo!);
    } else {
      previewPicture = current;
      previewPhoto = widget.currentPhoto;
    }
    final height = MediaQuery.sizeOf(context).height;
    return ScaffoldMessenger(
      key: _messenger,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SizedBox(
          height: height < 700 ? height : 700,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: p.borderSoft,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Row(
                  children: [
                    SheetTextButton(
                      key: const Key('channel-picture-cancel'),
                      label: 'Cancel',
                      color: p.accentUser,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        'Channel picture',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    SheetTextButton(
                      key: const Key('channel-picture-done'),
                      label: 'Done',
                      color: p.accentUser,
                      bold: true,
                      onTap: () => Navigator.of(context).pop(_choice),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ChannelPictureView(
                  name: widget.name,
                  colorSeed: widget.colorSeed,
                  picture: previewPicture,
                  photo: previewPhoto,
                  size: 96,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                PictureTabs(
                  symbolTab: _symbolTab,
                  onTab: (s) => setState(() => _symbolTab = s),
                ),
                const SizedBox(height: 16),
                if (_symbolTab)
                  SymbolPanel(
                    symbol: _symbol,
                    color: _color,
                    onSymbol: (s) => setState(() => _symbol = s),
                    onColor: (c) => setState(() => _color = c),
                  )
                else
                  PhotoRowsCard(
                    rows: [
                      PhotoRow(
                        'channel-picture-library',
                        Icons.photo_library_outlined,
                        'Choose from Photos',
                        () => _pickFrom(ImageSource.gallery),
                      ),
                      PhotoRow(
                        'channel-picture-camera',
                        Icons.photo_camera_outlined,
                        'Take Photo',
                        () => _pickFrom(ImageSource.camera),
                      ),
                      if (widget.room != null)
                        PhotoRow(
                          'channel-picture-from-chat',
                          Icons.chat_bubble_outline,
                          "Pick from this chat's photos",
                          _pickFromChat,
                        ),
                    ],
                  ),
                if (current != null && current is! NoPicture) ...[
                  const SizedBox(height: 12),
                  SheetTextButton(
                    key: const Key('channel-picture-remove'),
                    label: 'Remove picture',
                    color: p.warningTone,
                    onTap: () => Navigator.of(context).pop(const ChooseNone()),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
