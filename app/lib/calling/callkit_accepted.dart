/// Whether CallKit already shows [callId] as answered, from the plugin's
/// `activeCalls()` result.
///
/// On a cold wake the user can tap Answer before Dart is listening for CallKit
/// events, and the plugin drops events nobody is listening for. Its call list
/// still records the answer, so the controller asks once the invite lands.
bool callKitAccepted(Object? activeCalls, String callId) {
  if (activeCalls is! List) return false;
  final want = callId.toLowerCase();
  for (final c in activeCalls) {
    if (c is! Map) continue;
    final id = c['id'];
    if (id is! String || id.toLowerCase() != want) continue;
    if (c['isAccepted'] == true || c['accepted'] == true) return true;
  }
  return false;
}
