import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:littlelove/conversation/link_preview.dart';

void main() {
  group('firstUrl', () {
    test('finds an https url in a sentence', () {
      expect(
        firstUrl('see https://example.com/x now'),
        'https://example.com/x',
      );
    });
    test('strips trailing sentence punctuation', () {
      expect(firstUrl('go to https://example.com.'), 'https://example.com');
    });
    test('returns null when there is no url', () {
      expect(firstUrl('no link here'), isNull);
    });
  });

  test('fetchLinkPreview parses OG tags (no image)', () async {
    final client = MockClient((req) async {
      return http.Response(
        '<html><head>'
        '<meta property="og:title" content="Hello World">'
        '<meta property="og:description" content="A description">'
        '<meta property="og:site_name" content="Example">'
        '</head></html>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });
    final p = await fetchLinkPreview(
      'https://example.com/post',
      client: client,
    );
    expect(p, isNotNull);
    expect(p!.title, 'Hello World');
    expect(p.description, 'A description');
    expect(p.siteName, 'Example');
    expect(p.imageB64, isNull);
    expect(p.hasContent, isTrue);
  });

  test('fetchLinkPreview falls back to <title> and host', () async {
    final client = MockClient((req) async {
      return http.Response(
        '<html><head><title>Bare Title</title></head></html>',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final p = await fetchLinkPreview(
      'https://news.site/article',
      client: client,
    );
    expect(p, isNotNull);
    expect(p!.title, 'Bare Title');
    expect(p.siteName, 'news.site');
  });

  test('fetchLinkPreview downscales the og:image and records its dims', () async {
    final src = img.Image(width: 200, height: 100);
    img.fill(src, color: img.ColorRgb8(10, 20, 30));
    final png = img.encodePng(src);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('.png')) {
        return http.Response.bytes(
          png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }
      return http.Response(
        '<html><head>'
        '<meta property="og:title" content="With Image">'
        '<meta property="og:image" content="https://cdn.example.com/p.png">'
        '</head></html>',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final p = await fetchLinkPreview(
      'https://example.com/post',
      client: client,
    );
    expect(p, isNotNull);
    expect(p!.imageB64, isNotNull);
    // Dimensions are the original's, so the card can use the true aspect ratio.
    expect(p.imageWidth, 200);
    expect(p.imageHeight, 100);
  });

  test('fetchLinkPreview returns null for non-HTML content', () async {
    final client = MockClient(
      (req) async => http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(
      await fetchLinkPreview('https://api.example.com/data', client: client),
      isNull,
    );
  });

  test('fetchLinkPreview returns null on a non-200 response', () async {
    final client = MockClient((req) async => http.Response('nope', 404));
    expect(
      await fetchLinkPreview('https://example.com/missing', client: client),
      isNull,
    );
  });

  test('fetchLinkPreview rejects non-http schemes without a request', () async {
    var called = false;
    final client = MockClient((req) async {
      called = true;
      return http.Response('', 200);
    });
    expect(await fetchLinkPreview('ftp://example.com', client: client), isNull);
    expect(called, isFalse);
  });
}
