import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../identity/bip39.dart';
import '../../onboarding/onboarding_header.dart';
import '../../onboarding/phrase_grid.dart';
import '../../theme/app_palette.dart';
import '../../theme/twilight.dart';

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
    setState(() {
      _phrase = phrase;
      _username = _usernameCtl.text;
    });
    // Do not fire onPhraseReady yet — the user must SEE the phrase before
    // we advance to confirmation (spec §3.1 step 6). The "I've saved these
    // words" button in _step2 fires it.
  }

  void _copyPhrase(String phrase) {
    Clipboard.setData(ClipboardData(text: phrase));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Copied. Paste it somewhere safe, then clear your clipboard.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phrase = _phrase;
    return Scaffold(
      appBar: AppBar(),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: phrase == null ? _step1() : _step2(phrase),
      ),
    );
  }

  Widget _step1() {
    final palette = context.palette;
    final showError = _usernameCtl.text.isNotEmpty && !_usernameValid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OnboardingHeader(title: 'Pick a username'),
        const SizedBox(height: 10),
        Text(
          'This is how your partner finds you. Lowercase letters, numbers, '
          'and underscores.',
          style: TwilightType.lede.copyWith(color: palette.textMuted),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _usernameCtl,
          autocorrect: false,
          decoration: InputDecoration(
            hintText: 'username',
            errorText: showError ? '3–20 chars, lowercase a-z 0-9 _' : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: palette.accentUser,
            foregroundColor: palette.bgCanvas,
            minimumSize: const Size.fromHeight(52),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(2)),
            ),
          ),
          onPressed: _usernameValid ? _create : null,
          child: const Text('Create account'),
        ),
      ],
    );
  }

  Widget _step2(String phrase) {
    final palette = context.palette;
    final words = phrase.split(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OnboardingHeader(
          step: 'Step 1 of 2 · Recovery phrase',
          title: 'Save these 12 words',
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.vpn_key_outlined, size: 16, color: palette.accentUser),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'These 12 words are your key back in. Tuck them somewhere '
                'safe and private, just for the two of you.',
                style: TwilightType.lede.copyWith(
                  fontSize: 13,
                  color: palette.textMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(child: PhraseGrid(words: words)),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.accentSage,
            side: BorderSide(color: palette.accentSage.withValues(alpha: 0.5)),
            minimumSize: const Size.fromHeight(46),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: () => _copyPhrase(phrase),
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('Copy all 12 words'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('phrase-saved'),
          style: FilledButton.styleFrom(
            backgroundColor: palette.accentUser,
            foregroundColor: palette.bgCanvas,
            minimumSize: const Size.fromHeight(52),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(2)),
            ),
          ),
          onPressed: () => widget.onPhraseReady(_username!, phrase),
          child: const Text("I've saved these words"),
        ),
      ],
    );
  }
}
