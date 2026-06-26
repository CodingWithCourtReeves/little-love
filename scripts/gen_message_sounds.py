#!/usr/bin/env python3
"""Synthesize the chat message-sound effects (sent / received).

Pure-stdlib (wave + struct + math) so it runs anywhere without numpy. Writes
16-bit mono 44.1kHz PCM WAVs that AudioServicesPlaySystemSound can play
directly. These are tasteful defaults — swap the .wav files anytime; the app
just plays whatever is bundled at assets/audio/message_{sent,received}.wav.

    python3 scripts/gen_message_sounds.py

Design: short, soft, slightly warm (a touch of 2nd harmonic), click-free
(raised-cosine attack + exponential decay). "sent" is a quick rising blip;
"received" is a gentle two-note rise.
"""
import math
import os
import struct
import wave

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "app", "assets", "audio")


def _env(i, n, attack_s, decay_tau):
    """Raised-cosine attack into an exponential decay — no start/end clicks."""
    t = i / SR
    attack_n = max(1, int(attack_s * SR))
    a = 0.5 - 0.5 * math.cos(math.pi * min(i, attack_n) / attack_n)
    return a * math.exp(-t / decay_tau)


def _tone(freq_start, freq_end, dur_s, amp, decay_tau, attack_s=0.004):
    """A glide from freq_start→freq_end with a soft 2nd harmonic."""
    n = int(dur_s * SR)
    out = []
    phase = 0.0
    for i in range(n):
        frac = i / n
        f = freq_start + (freq_end - freq_start) * frac
        phase += 2 * math.pi * f / SR
        s = math.sin(phase) + 0.18 * math.sin(2 * phase)
        out.append(amp * _env(i, n, attack_s, decay_tau) * s)
    return out


def _silence(dur_s):
    return [0.0] * int(dur_s * SR)


def _write(path, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    norm = min(1.0, 0.9 / peak)  # leave a touch of headroom
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s * norm)) * 32767))
            for s in samples
        )
        w.writeframes(frames)
    print(f"wrote {path} ({len(samples)/SR*1000:.0f} ms)")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # Sent: a quick, soft rising blip.
    sent = _tone(620, 980, 0.11, amp=0.5, decay_tau=0.05)
    _write(os.path.join(OUT_DIR, "message_sent.wav"), sent)

    # Received: a gentle two-note rise (G5 → D6).
    received = (
        _tone(784, 784, 0.07, amp=0.45, decay_tau=0.06)
        + _silence(0.015)
        + _tone(1175, 1175, 0.12, amp=0.5, decay_tau=0.08)
    )
    _write(os.path.join(OUT_DIR, "message_received.wav"), received)


if __name__ == "__main__":
    main()
