import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../identity/account_local.dart';
import '../../identity/bip39.dart';
import '../../identity/keypair.dart';
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
  final _phraseCtl = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _signin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Uint8List seed = phraseToSeed(_phraseCtl.text.trim());
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
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('username'),
              controller: _usernameCtl,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('phrase'),
              controller: _phraseCtl,
              autocorrect: false,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '12-word recovery phrase',
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _signin,
              child: const Text('Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
