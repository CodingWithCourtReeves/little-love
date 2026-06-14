import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../inbox/read_state_store.dart';
import '../wire/rest_client.dart';
import 'account_local.dart';
import 'keystore.dart';

class ServerEndpoint {
  ServerEndpoint(this.httpBase);
  final Uri httpBase;

  Uri get wsConnect {
    final scheme = httpBase.scheme == 'https' ? 'wss' : 'ws';
    return httpBase.replace(scheme: scheme, path: '/ws');
  }
}

const _defaultServer = String.fromEnvironment(
  'LLOVE_SERVER',
  defaultValue: 'http://127.0.0.1:7707',
);

final serverBaseProvider = Provider<Uri>((_) => Uri.parse(_defaultServer));

final serverEndpointProvider = Provider<ServerEndpoint>(
  (ref) => ServerEndpoint(ref.watch(serverBaseProvider)),
);

final httpClientProvider = Provider<http.Client>((_) => http.Client());

final restClientProvider = Provider<RestClient>((ref) {
  return RestClient(
    baseUri: ref.watch(serverEndpointProvider).httpBase,
    httpClient: ref.watch(httpClientProvider),
  );
});

final keystoreProvider = Provider<Keystore>((_) => SecureKeystore());

final accountLocalStoreProvider = Provider<AccountLocalStore>(
  (_) => AccountLocalStore(),
);

final readStateStoreProvider = Provider<ReadStateStore>(
  (ref) => ReadStateStore(),
);

final accountProvider = FutureProvider<LocalAccount?>((ref) async {
  final store = ref.watch(accountLocalStoreProvider);
  return store.load();
});
