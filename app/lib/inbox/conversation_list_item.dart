import 'package:flutter/material.dart';

import '../conversation/status_marker.dart';
import '../conversation/time_format.dart';
import '../theme/app_palette.dart';
import '../theme/twilight.dart';
import 'room_preview.dart';

/// One room on the home screen, laid out like a chat list (Messages, WhatsApp,
/// Telegram): the name and the latest message's time on top, then two lines of
/// preview with the unread count beside it. The whole row is the tap target.
///
/// Every row is the same height whatever its preview holds: the preview always
/// reserves two lines (scaled with the system text size), so a list of short
/// and long messages doesn't jump.
class ConversationListItem extends StatelessWidget {
  const ConversationListItem({
    super.key,
    required this.label,
    required this.onTap,
    this.preview = const RoomPreview(),
    this.leading,
    this.now,
  });

  final String label;
  final VoidCallback onTap;
  final RoomPreview preview;

  /// Optional leading widget (the partner's avatar) shown before the text.
  final Widget? leading;

  /// The moment the time label is relative to; null means the clock. Lets a
  /// test pin "today" so "9:41 PM" vs "Yesterday" is deterministic.
  final DateTime? now;

  static const _previewSize = 15.0;
  static const _previewLineHeight = 20 / _previewSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final at = preview.at;
    final unread = preview.unread;
    // Two preview lines at the user's text size, reserved even when the text
    // fits on one, so every row is the same height.
    final previewBox =
        MediaQuery.textScalerOf(context).scale(_previewSize) *
        _previewLineHeight *
        2;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: p.borderSoft, width: 0.5),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 16, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TwilightType.body.copyWith(
                                    fontSize: 16,
                                    height: 1.25,
                                    fontWeight: FontWeight.w600,
                                    color: p.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (preview.failed)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Icon(
                                    Icons.error,
                                    key: const Key('row-send-failed'),
                                    size: 15,
                                    color: p.warningTone,
                                    semanticLabel: 'Not sent',
                                  ),
                                ),
                              if (preview.mark != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: StatusMarker(preview.mark!),
                                ),
                              if (at != null)
                                Text(
                                  listTimeLabel(
                                    at.toLocal(),
                                    now: now ?? DateTime.now(),
                                  ),
                                  key: const Key('row-time'),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: unread > 0
                                        ? FontWeight.w500
                                        : FontWeight.w400,
                                    color: unread > 0
                                        ? p.accentUser
                                        : p.textMuted,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: previewBox,
                                  child: Text.rich(
                                    _previewSpan(p),
                                    key: const Key('row-preview'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (unread > 0) ...[
                                const SizedBox(width: 10),
                                _UnreadCount(unread),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  TextSpan _previewSpan(AppPalette p) {
    final color = switch (preview.tone) {
      PreviewTone.live => p.accentUser,
      PreviewTone.warning => p.warningTone,
      PreviewTone.plain || PreviewTone.placeholder => p.textMuted,
    };
    final icon = preview.icon;
    return TextSpan(
      style: TwilightType.body.copyWith(
        fontSize: _previewSize,
        height: _previewLineHeight,
        color: color,
        fontStyle: preview.tone == PreviewTone.placeholder
            ? FontStyle.italic
            : FontStyle.normal,
      ),
      children: [
        if (preview.fromMe)
          TextSpan(
            text: 'You: ',
            style: TextStyle(color: p.textPrimary),
          ),
        if (preview.isDraft)
          TextSpan(
            text: 'Draft: ',
            style: TextStyle(color: p.warningTone, fontWeight: FontWeight.w500),
          ),
        if (icon != null)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                switch (icon) {
                  PreviewIcon.photo => Icons.photo_camera_outlined,
                  PreviewIcon.video => Icons.videocam_outlined,
                  PreviewIcon.voice => Icons.mic_none,
                  PreviewIcon.call => Icons.call_outlined,
                },
                size: 16,
                color: color,
              ),
            ),
          ),
        TextSpan(text: preview.text),
      ],
    );
  }
}

/// The unread count badge, capped at "99+".
class _UnreadCount extends StatelessWidget {
  const _UnreadCount(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('unread-count'),
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: context.palette.accentUser,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1.0,
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }
}
