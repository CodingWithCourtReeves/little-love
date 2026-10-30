/// The love tap (#76): a one-tap ❤️ sent from the empty composer.
///
/// A love tap is an ordinary text message whose body is just the heart, so it
/// needs no new message kind, nothing changes on the wire or server, and it
/// renders through the existing jumbomoji path. What makes it a love tap is
/// only how it *feels*: a heartbeat haptic and a heart burst, on both sides.
library;

/// The body a love tap sends.
const loveTapBody = '❤️';

/// True when [body] is a love tap. A heart typed by hand counts too, on
/// purpose: it is the same message, so it gets the same feel. The bare U+2764
/// (no variation selector) is accepted because some keyboards send it.
bool isLoveTap(String body) {
  final t = body.trim();
  return t == loveTapBody || t == '❤';
}
