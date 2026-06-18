import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../attachment/thumbnail.dart';

/// A link preview embedded in a text message. Fetched on the SENDER's device
/// from the page's Open Graph / Twitter-card / `<title>` tags, then carried
/// inside the encrypted message body so the recipient renders it without ever
/// touching the network — keeping previews end-to-end private (the server and
/// the recipient never see the URL just to draw a card). [imageB64] is a small
/// downscaled JPEG so the whole message stays under the per-recipient body cap.
class LinkPreview {
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.siteName,
    this.imageB64,
    this.imageWidth,
    this.imageHeight,
  });

  final String url;
  final String? title;
  final String? description;
  final String? siteName;
  final String? imageB64;

  /// Original (pre-downscale) pixel dimensions of [imageB64], so the card can
  /// render the preview at its true aspect ratio (dynamic height) instead of
  /// cropping it to a fixed banner.
  final int? imageWidth;
  final int? imageHeight;

  /// True when there's enough to draw a card (more than just the bare URL).
  bool get hasContent =>
      (title != null && title!.isNotEmpty) ||
      (description != null && description!.isNotEmpty) ||
      (imageB64 != null && imageB64!.isNotEmpty);

  Map<String, Object?> toJson() => {
    'url': url,
    if (title != null && title!.isNotEmpty) 'title': title,
    if (description != null && description!.isNotEmpty) 'desc': description,
    if (siteName != null && siteName!.isNotEmpty) 'site': siteName,
    if (imageB64 != null && imageB64!.isNotEmpty) 'img': imageB64,
    if (imageWidth != null) 'iw': imageWidth,
    if (imageHeight != null) 'ih': imageHeight,
  };

  factory LinkPreview.fromJson(Map<String, Object?> j) => LinkPreview(
    url: (j['url'] as String?) ?? '',
    title: j['title'] as String?,
    description: j['desc'] as String?,
    siteName: j['site'] as String?,
    imageB64: j['img'] as String?,
    imageWidth: (j['iw'] as num?)?.toInt(),
    imageHeight: (j['ih'] as num?)?.toInt(),
  );
}

final _urlPattern = RegExp(r'https?://[^\s<]+', caseSensitive: false);

/// The first http(s) URL in [text], or null. Trailing punctuation that's
/// clearly not part of the URL is trimmed.
String? firstUrl(String text) {
  final m = _urlPattern.firstMatch(text);
  if (m == null) return null;
  var url = m.group(0)!;
  // Strip trailing sentence punctuation a user likely didn't mean to include.
  while (url.isNotEmpty && '.,);!?\'"'.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return url.isEmpty ? null : url;
}

// Bigger than an inline message thumb because the card shows it at full aspect
// ratio. Capped so the whole message (image is base64'd into the body, then
// the body is encrypted + base64'd again ≈ 1.8×) stays under the 96 KiB
// per-recipient body limit even alongside the text/title/description.
const _previewMaxImageEdge = 600;
const _previewMaxImageBytes = 40 * 1024;
const _fetchTimeout = Duration(seconds: 6);

/// Fetch a [LinkPreview] for [url] from the SENDER's device. Best-effort:
/// returns null on any failure (non-HTML, timeout, no usable tags) so a send
/// never blocks on a flaky site. [client] is injectable for tests.
Future<LinkPreview?> fetchLinkPreview(String url, {http.Client? client}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  final c = client ?? http.Client();
  try {
    final resp = await c
        .get(
          uri,
          headers: const {
            'User-Agent': 'Mozilla/5.0 (compatible; LittleLovePreview/1.0)',
            'Accept': 'text/html,application/xhtml+xml',
          },
        )
        .timeout(_fetchTimeout);
    if (resp.statusCode != 200) return null;
    final contentType = (resp.headers['content-type'] ?? '').toLowerCase();
    if (!contentType.contains('html')) return null;

    final doc = html_parser.parse(resp.body);
    String? meta(String key) {
      final el =
          doc.querySelector('meta[property="$key"]') ??
          doc.querySelector('meta[name="$key"]');
      final content = el?.attributes['content']?.trim();
      return (content == null || content.isEmpty) ? null : content;
    }

    final title =
        meta('og:title') ??
        meta('twitter:title') ??
        doc.querySelector('title')?.text.trim();
    final description =
        meta('og:description') ??
        meta('twitter:description') ??
        meta('description');
    final siteName = meta('og:site_name') ?? uri.host;
    final imageUrl =
        meta('og:image') ?? meta('og:image:url') ?? meta('twitter:image');

    final image = imageUrl == null
        ? null
        : await _fetchImageThumb(c, uri.resolve(imageUrl));

    final preview = LinkPreview(
      url: url,
      title: title,
      description: description,
      siteName: siteName,
      imageB64: image?.b64,
      imageWidth: image?.width,
      imageHeight: image?.height,
    );
    return preview.hasContent ? preview : null;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

Future<({String b64, int width, int height})?> _fetchImageThumb(
  http.Client c,
  Uri imageUri,
) async {
  try {
    final resp = await c.get(imageUri).timeout(_fetchTimeout);
    if (resp.statusCode != 200) return null;
    if (resp.bodyBytes.length > 8 * 1024 * 1024) return null; // sanity cap
    final thumb = await buildImageThumbnail(
      resp.bodyBytes,
      maxEdge: _previewMaxImageEdge,
      maxThumbBytes: _previewMaxImageBytes,
    );
    return (
      b64: base64.encode(thumb.jpeg),
      width: thumb.width,
      height: thumb.height,
    );
  } catch (_) {
    // Undecodable (e.g. SVG/unsupported WebP) or network error: skip the image.
    return null;
  }
}
