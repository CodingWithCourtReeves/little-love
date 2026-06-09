import 'package:flutter/material.dart';

import '../../identity/bip39.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, required this.onPhraseReady});

  /// Called with (username, phrase) once the recovery phrase has been shown
  /// to the user. Callers should then route to a confirmation screen.
  final void Function(String username, String phrase) onPhraseReady;

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _usernameCtl = TextEditingController();
  String? _phrase;
  String? _username;

  static final _usernameRegex = RegExp(r'^[a-z0-9_]{3,20}$');

  bool get _usernameValid => _usernameRegex.hasMatch(_usernameCtl.text);

  void _create() {
    final seed = generateSeed();
    final phrase = seedToPhrase(seed);
    final username = _usernameCtl.text;
    setState(() {
      _phrase = phrase;
      _username = username;
    });
    widget.onPhraseReady(username, phrase);
  }

  @override
  Widget build(BuildContext context) {
    final phrase = _phrase;
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: phrase == null ? _step1() : _step2(phrase),
      ),
    );
  }

  Widget _step1() {
    final showError = _usernameCtl.text.isNotEmpty && !_usernameValid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Pick a username'),
        const SizedBox(height: 12),
        TextField(
          controller: _usernameCtl,
          autocorrect: false,
          decoration: InputDecoration(
            hintText: 'court',
            errorText: showError ? '3–20 chars, lowercase a-z 0-9 _' : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _usernameValid ? _create : null,
          child: const Text('Create account'),
        ),
      ],
    );
  }

  Widget _step2(String phrase) {
    final words = phrase.split(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Save these 12 words. They are the only way to restore '
          '@${_username ?? ''}.',
        ),
        const SizedBox(height: 16),
        GridView.builder(
          shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 3,
          ),
          itemCount: 12,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.all(4),
            child: Text('${i + 1}. ${words[i]}'),
          ),
        ),
      ],
    );
  }
}
