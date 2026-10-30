/// The look shared by the chat-info page and the pages it opens (#91, #92):
/// the chat's own wallpaper under a [veilAlpha] veil, a transparent app bar
/// with a floating back pill, and frosted [InfoSection] cards of [InfoRow]s.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_palette.dart';
import '../wallpaper/wallpaper_background.dart';

/// Opacity of the `bgCanvas` veil over the wallpaper. Bare text can't reach
/// 4.5:1 on any shipped wallpaper (Twilight is mid-tone), so these pages tone
/// the wallpaper down instead: at this strength `textPrimary` and
/// `separatorText` pass everywhere (checked in `chat_info_page_test.dart`).
const double veilAlpha = 0.6;

/// Opacity of the frosted cards and tiles that sit on the veil.
const double cardAlpha = 0.85;

/// The fill of a card or tile on these pages.
Color infoCardColor(AppPalette p) =>
    p.bubblePartnerBg.withValues(alpha: cardAlpha);

/// A page on the chat's wallpaper: veil, transparent app bar with a back pill
/// (and an optional [title]), and [body] below the status bar.
class InfoScaffold extends StatelessWidget {
  const InfoScaffold({super.key, this.title, required this.body});

  final String? title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        centerTitle: true,
        // Status-bar icons follow the palette, which follows the wallpaper.
        systemOverlayStyle: p.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: title == null
            ? null
            : Text(
                title!,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
        leading: Navigator.of(context).canPop()
            ? IconButton(
                key: const Key('chat-info-back'),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: infoCardColor(p),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new,
                    color: p.textPrimary,
                    size: 18,
                  ),
                ),
              )
            : null,
      ),
      body: WallpaperBackground(
        // A Material (not a ColoredBox) so the rows' ink paints on the veil
        // rather than under it.
        child: Material(
          color: p.bgCanvas.withValues(alpha: veilAlpha),
          // Below the status bar and the (transparent) toolbar, so nothing
          // starts or scrolls up under the back pill.
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(top: kToolbarHeight),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// A captioned group of rows on a frosted card, iOS inset-grouped style.
class InfoSection extends StatelessWidget {
  const InfoSection({super.key, this.caption, required this.children});

  /// Small heading above the card ("SHARED"), or null for none.
  final String? caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 6),
              child: Text(
                caption!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: p.separatorText,
                ),
              ),
            ),
          Material(
            color: infoCardColor(p),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 50,
                      color: p.borderSoft.withValues(alpha: 0.7),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One tappable row of an [InfoSection]: icon, label, an optional trailing
/// [value] and a chevron, at least 48pt tall.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: p.accentUser, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 16, color: p.textPrimary),
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                Text(
                  value!,
                  style: TextStyle(fontSize: 15, color: p.separatorText),
                ),
              ],
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, color: p.separatorText, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
