import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/account_local.dart';
import '../../identity/bip39.dart';
import '../../identity/keypair.dart';
import '../../identity/providers.dart';
import '../../wire/rest_client.dart';
import 'home_placeholder.dart';
import 'recovery_confirm.dart';
import 'signin.dart';
import 'signup.dart';

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return account.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load account: $e'),
          ),
        ),
      ),
      data: (acc) =>
          acc == null ? const _ChoiceScreen() : HomePlaceholder(account: acc),
    );
  }
}

class _ChoiceScreen extends StatelessWidget {
  const _ChoiceScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to LittleLove')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _SignupFlow(),
                ),
              ),
              child: const Text('Create account'),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _SigninFlow(),
                ),
              ),
              child: const Text('Sign in with recovery phrase'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignupFlow extends ConsumerStatefulWidget {
  const _SignupFlow();
  @override
  ConsumerState<_SignupFlow> createState() => _SignupFlowState();
}

class _SignupFlowState extends ConsumerState<_SignupFlow> {
  String? _phrase;
  String? _username;

  @override
  Widget build(BuildContext context) {
    final phrase = _phrase;
    if (phrase == null) {
      return SignupScreen(onPhraseReady: (u, p) {
        setState(() {
          _username = u;
          _phrase = p;
        });
      });
    }
    return RecoveryConfirmScreen(
      phrase: phrase,
      onConfirmed: () => _commit(phrase),
    );
  }

  Future<void> _commit(String phrase) async {
    if (_username == null) return;
    final seed = phraseToSeed(phrase);
    final id = await deriveIdentity(seed);
    final rest = ref.read(restClientProvider);
    final keystore = ref.read(keystoreProvider);
    final store = ref.read(accountLocalStoreProvider);
    try {
      final reply = await rest.postAccount(
        username: _username!,
        ed25519PubBase64: base64.encode(id.ed25519PublicKey),
        x25519PubBase64: base64.encode(id.x25519PublicKey),
      );
      await keystore.write('llove.master.${_username!}', base64.encode(seed));
      await store.save(LocalAccount(
        username: reply.username,
        ed25519PubBase64: base64.encode(id.ed25519PublicKey),
        x25519PubBase64: base64.encode(id.x25519PublicKey),
        createdAt: reply.createdAt,
      ));
      ref.invalidate(accountProvider);
      if (mounted) Navigator.of(context).pop();
    } on UsernameTakenException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That username is already taken.')),
      );
    }
  }
}

class _SigninFlow extends ConsumerWidget {
  const _SigninFlow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SigninScreen(
      rest: ref.watch(restClientProvider),
      onRestored: (acc, seed) async {
        final keystore = ref.read(keystoreProvider);
        final store = ref.read(accountLocalStoreProvider);
        await keystore.write(
          'llove.master.${acc.username}',
          base64.encode(seed),
        );
        await store.save(acc);
        ref.invalidate(accountProvider);
        if (context.mounted) Navigator.of(context).pop();
      },
    );
  }
}
