import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../identity/account_local.dart';
import '../../identity/bip39.dart';
import '../../identity/keypair.dart';
import '../../onboarding/onboarding_header.dart';
import '../../onboarding/phrase_input.dart';
import '../../theme/app_palette.dart';
import '../../theme/twilight.dart';
import '../../wire/rest_client.dart';

class SigninScreen extends StatefulWidget {
  const SigninScreen({super.key, required this.rest, required this.onRestored});

  final RestClient rest;

  /// Called with the restored LocalAccount and the raw 16-byte seed so the
  /// caller can persist it to the keystore.
  final void Function(LocalAccount account, List<int> masterSeed) onRestored;

  @override
  State<SigninScreen> createState() => _SigninScreenState();
}

class _SigninScreenState extends State<SigninScreen> {
  final _usernameCtl = TextEditingController();
  String _phrase = '';
  String? _error;
  bool _busy = false;

  /// The 12 boxes are full and the username is present.
  bool get _ready =>
      _usernameCtl.text.trim().isNotEmpty &&
      _phrase.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length == 12;

  Future<void> _signin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Uint8List seed = phraseToSeed(_phrase.trim());
      final id = await deriveIdentity(seed);
      final username = _usernameCtl.text.trim();
      final acc = await widget.rest.getAccountByUsername(username);
      if (acc == null) {
        setState(() => _error = 'There is no account named @$username.');
        return;
      }
      if (acc.ed25519PubBase64 != base64.encode(id.ed25519PublicKey) ||
          acc.x25519PubBase64 != base64.encode(id.x25519PublicKey)) {
        setState(
          () => _error =
              'That phrase belongs to a different account, not @$username.',
        );
        return;
      }
      widget.onRestored(
        LocalAccount(
          username: acc.username,
          ed25519PubBase64: acc.ed25519PubBase64,
          x25519PubBase64: acc.x25519PubBase64,
          createdAt: acc.createdAt,
        ),
        seed,
      );
    } on FormatException catch (e) {
      setState(() => _error = 'Invalid recovery phrase: ${e.message}');
    } catch (e) {
      setState(() => _error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const OnboardingHeader(title: 'Welcome back'),
            const SizedBox(height: 10),
            Text(
              'Enter your username and the 12 words you saved.',
              style: TwilightType.lede.copyWith(color: palette.textMuted),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const ValueKey('username'),
              controller: _usernameCtl,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),
            Text(
              'RECOVERY PHRASE',
              style: TwilightType.annotation.copyWith(
                color: palette.accentSage,
              ),
            ),
            const SizedBox(height: 4),
            PhraseInput(onChanged: (p) => setState(() => _phrase = p)),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(_error!, style: TextStyle(color: palette.warningTone)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: palette.accentUser,
                foregroundColor: palette.bgCanvas,
                minimumSize: const Size.fromHeight(52),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
              onPressed: (_busy || !_ready) ? null : _signin,
              child: const Text('Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
