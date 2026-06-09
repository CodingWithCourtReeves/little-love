import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'config.dart';
import 'conversation_page.dart';
import 'theme/twilight.dart';
import 'wire/crypto.dart';
import 'wire/message.dart';
import 'ws_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LittleLoveApp());
}

class LittleLoveApp extends StatelessWidget {
  const LittleLoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LittleLove',
      theme: buildTwilightTheme(),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  AppConfig? _config;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cfg = await AppConfig.load();
      setState(() => _config = cfg);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'LittleLove could not start.\n\n$_error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    if (_config == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _Live(config: _config!);
  }
}

class _Live extends StatefulWidget {
  const _Live({required this.config});
  final AppConfig config;

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  late final WsClient _ws;
  late final SymmetricCipher? _cipher;
  final _messages = <Msg>[];
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    final keyHex = widget.config.sharedKeyHex;
    _cipher = (keyHex != null) ? SymmetricCipher.fromHex(keyHex) : null;
    _ws = WsClient(
      url: widget.config.serverUrl,
      username: widget.config.username,
    );
    _ws.incoming.listen(_onIncoming);
    // ignore: unawaited_futures
    _ws.start();
  }

  Future<void> _onIncoming(Msg m) async {
    String body = m.body;
    final cipher = _cipher;
    if (cipher != null) {
      try {
        body = await cipher.decrypt(EncryptedBody.fromWireString(m.body));
      } catch (_) {
        body = '⚠ could not decrypt';
      }
    }
    setState(() {
      _messages.add(
        Msg(
          id: m.id,
          from: m.from,
          to: m.to,
          body: body,
          ts: m.ts,
          replayed: m.replayed,
        ),
      );
    });
  }

  Future<void> _send(String text) async {
    final cipher = _cipher;
    final wireBody = (cipher != null)
        ? (await cipher.encrypt(text)).toWireString()
        : text;
    final msg = Msg(
      id: _uuid.v4(),
      from: widget.config.username,
      to: widget.config.contactUsername,
      body: wireBody,
      ts: DateTime.now().toUtc(),
    );
    _ws.send(msg);
    setState(() {
      _messages.add(
        Msg(
          id: msg.id,
          from: msg.from,
          to: msg.to,
          body: text,
          ts: msg.ts,
          replayed: false,
        ),
      );
    });
  }

  @override
  void dispose() {
    _ws.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConversationPage(
      meUsername: widget.config.username,
      contactDisplayName: widget.config.contactDisplayName,
      messages: _messages,
      onSend: _send,
    );
  }
}
