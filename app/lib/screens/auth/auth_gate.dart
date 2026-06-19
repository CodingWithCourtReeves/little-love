import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/account_local.dart';
import '../../identity/bip39.dart';
import '../../identity/keypair.dart';
import '../../identity/providers.dart';
import '../../outbox/outbox_rehydrate.dart';
import '../../theme/twilight.dart';
import '../../wire/rest_client.dart';
import '../inbox/home_screen.dart';
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
      data: (acc) => acc == null
          ? const _ChoiceScreen()
          : OutboxRehydrateGate(child: HomeScreen(account: acc)),
    );
  }
}

class _ChoiceScreen extends StatelessWidget {
  const _ChoiceScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'A messenger for two.',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 40,
                      fontWeight: FontWeight.w500,
                      height: 1.06,
                      letterSpacing: -1.0,
                      color: TwilightColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Conversations live only on devices you own. '
                    'The server holds ciphertext it cannot read.',
                    style: TwilightType.lede,
                  ),
                  const SizedBox(height: 48),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: TwilightColors.textPrimary,
                      foregroundColor: TwilightColors.bgCanvas,
                      minimumSize: const Size.fromHeight(52),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(2)),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _SignupFlow(),
                      ),
                    ),
                    child: const Text('Create an account'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TwilightColors.textPrimary,
                      side: const BorderSide(color: TwilightColors.borderSoft),
                      minimumSize: const Size.fromHeight(52),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(2)),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _SigninFlow(),
                      ),
                    ),
                    child: const Text('Sign in with a recovery phrase'),
                  ),
                ],
              ),
            ),
          ),
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
      return SignupScreen(
        onPhraseReady: (u, p) {
          setState(() {
            _username = u;
            _phrase = p;
          });
        },
      );
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
      await store.save(
        LocalAccount(
          username: reply.username,
          ed25519PubBase64: base64.encode(id.ed25519PublicKey),
          x25519PubBase64: base64.encode(id.x25519PublicKey),
          createdAt: reply.createdAt,
        ),
      );
      ref.invalidate(accountProvider);
      if (mounted) Navigator.of(context).pop();
    } on UsernameTakenException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That username is already taken.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not finish signup: $e')));
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
