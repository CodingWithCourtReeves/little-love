import 'package:flutter/material.dart';

import '../../onboarding/onboarding_header.dart';
import '../../theme/app_palette.dart';
import '../../theme/twilight.dart';

class RecoveryConfirmScreen extends StatefulWidget {
  const RecoveryConfirmScreen({
    super.key,
    required this.phrase,
    required this.onConfirmed,
  });

  final String phrase;
  final VoidCallback onConfirmed;

  @override
  State<RecoveryConfirmScreen> createState() => _RecoveryConfirmScreenState();
}

class _RecoveryConfirmScreenState extends State<RecoveryConfirmScreen> {
  final _w3 = TextEditingController();
  final _w7 = TextEditingController();
  final _w11 = TextEditingController();
  String? _error;

  late final List<String> _words = widget.phrase.split(' ');

  bool get _allFilled =>
      _w3.text.trim().isNotEmpty &&
      _w7.text.trim().isNotEmpty &&
      _w11.text.trim().isNotEmpty;

  void _check() {
    final ok =
        _w3.text.trim() == _words[2] &&
        _w7.text.trim() == _words[6] &&
        _w11.text.trim() == _words[10];
    if (ok) {
      widget.onConfirmed();
    } else {
      setState(() => _error = 'That does not match. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const OnboardingHeader(
              step: 'Step 2 of 2 · Confirm',
              title: 'Confirm your phrase',
            ),
            const SizedBox(height: 10),
            Text(
              'Quick check. Type words 3, 7, and 11 so we know they '
              'landed safely.',
              style: TwilightType.lede.copyWith(color: palette.textMuted),
            ),
            const SizedBox(height: 20),
            _slot('Word 3', _w3),
            const SizedBox(height: 8),
            _slot('Word 7', _w7),
            const SizedBox(height: 8),
            _slot('Word 11', _w11),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: TextStyle(color: palette.warningTone)),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: palette.accentUser,
                foregroundColor: palette.bgCanvas,
                minimumSize: const Size.fromHeight(52),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
              onPressed: _allFilled ? _check : null,
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slot(String label, TextEditingController ctl) {
    return TextField(
      controller: ctl,
      autocorrect: false,
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => setState(() {}),
    );
  }
}
