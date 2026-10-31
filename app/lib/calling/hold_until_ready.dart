/// Holds items until [ready], then hands them (and every later item) to the
/// deliver callback in arrival order.
///
/// Call signaling needs this twice: a remote ICE candidate can't be added
/// before the remote description is set, and the callee can't decrypt or apply
/// one before it has answered. Candidates that arrive early are kept, not
/// dropped, so the two phones still learn each other's addresses.
class HoldUntilReady<T> {
  HoldUntilReady(this._deliver);

  final Future<void> Function(T item) _deliver;
  final List<T> _held = [];
  bool _ready = false;

  Future<void> add(T item) async {
    if (!_ready) {
      _held.add(item);
      return;
    }
    await _deliverSafely(item);
  }

  /// Deliver everything held so far; later items go straight through.
  Future<void> ready() async {
    if (_ready) return;
    _ready = true;
    final held = List<T>.of(_held);
    _held.clear();
    for (final item in held) {
      await _deliverSafely(item);
    }
  }

  // One bad candidate must not cost the others.
  Future<void> _deliverSafely(T item) async {
    try {
      await _deliver(item);
    } catch (_) {}
  }
}
