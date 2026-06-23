# Voice Memos — Design

**Date:** 2026-06-22
**Status:** Approved (design phase)
**Branch:** `worktree-voice-memos`

## Goal

Add Telegram-parity voice memos to the little-love chat app: hold-to-record
in the composer (with slide-to-cancel and lock-to-record), an E2EE audio
message kind, and a playback bubble with a real waveform, scrubbing, and
playback-speed control. Surface voice memos in the chat-info page's existing
"Voice" tab.

This is an **iOS-only, almost entirely client-side (Dart)** feature. The
backend stores message bodies as opaque ciphertext and never learns about the
new kind, so **no Rust changes and no migration are required**.

## Scope

In scope:
- New `kind:"audio"` message content, reusing the existing
  `AttachmentDescriptor` + E2EE upload/download flow.
- Full Telegram-parity recording UX: press-and-hold the existing composer mic,
  slide-left to cancel, slide-up to lock (hands-free), 5-minute auto-stop.
- Playback bubble: play/pause, waveform with progress fill, drag-to-scrub
  seek, elapsed/total time, tap-to-cycle speed (1× → 1.5× → 2×).
- Chat-info "Voice" tab populated with a list of voice memos; audio excluded
  from the visual Media grid.
- Live amplitude-sampled waveform (~64 normalized peaks) stored inside the
  encrypted descriptor.

Out of scope (not now):
- Android / desktop (project is iOS-only MVP).
- Voice memo transcription / speech-to-text.
- A persistent floating mini-player that survives navigation away from the
  conversation.
- Importing an existing audio file as a voice memo (recording-only for v1).

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Recording UX | Full Telegram parity: slide-to-cancel, lock-to-record |
| Chat-info | Fill existing "Voice" tab; exclude audio from Media grid |
| Waveform | Live amplitude sampling during recording → ~64 peaks |
| Max length | 5 minutes, auto-stop |
| Recording pkg | `record` (AAC-LC `.m4a`, amplitude stream) |
| Playback pkg | `just_audio` (seek/scrub + speed) |
| Backend | No changes, no migration |

## Architecture

### Data model

Add `AudioContent` as a fifth `MessageContent` kind in
`app/lib/conversation/message_content.dart`, parallel to `FileContent`:

```
kind: "audio"
descriptor: AttachmentDescriptor   // reused as-is, plus new waveform field
caption: String?                   // optional, like FileContent
```

`AudioContent` reuses the existing `AttachmentDescriptor`
(`app/lib/attachment/attachment_descriptor.dart`), which already carries
`blobKey`, `contentKeyB64`, `nonceB64`, `mime`, `filename`, `size`, and
`durationMs`. The audio `mime` is `audio/mp4` (AAC-LC in an `.m4a` container,
iOS-native).

**One descriptor addition:** an optional `waveform` field — a `List<int>` of
~64 peaks normalized to 0–31 (one byte each, ~64 bytes total). It serializes
as plain JSON inside the descriptor. Because the descriptor already rides
inside the encrypted message envelope, the waveform is E2EE for free — no
separate encrypted-thumbnail blob is needed. The descriptor stays far under
the server's 98 KiB base64 body cap; the audio bytes themselves go to the blob
store, never into the message body.

`MessageContent.decode()` already falls back to plain text on unknown kinds, so
older clients that don't understand `audio` degrade gracefully.

### New isolated units

Three new pure/wrapper units under `app/lib/audio/`, each independently
testable:

1. **`audio/waveform.dart`** — pure functions. Takes a stream/list of raw
   amplitude samples and downsamples to a fixed 64-bucket peak array, then
   normalizes to 0–31. No I/O. Fully unit-tested.

2. **`audio/recorder_controller.dart`** — wraps the `record` package. A small
   state machine: `idle → recording → (locked | cancelling) → stopped`.
   Exposes elapsed time, the live amplitude → peak accumulator, and
   `start() / stop() / cancel() / lock()`. Auto-stops at 5:00. State
   transitions are unit-tested with the platform channel mocked.

3. **`audio/playback_controller.dart`** — wraps `just_audio`. Enforces **one
   memo playing at a time**, exposes position / duration / speed, and
   `play(blobKey) / pause() / seek(pos) / cycleSpeed()` (1× → 1.5× → 2×).
   Exposed via a Riverpod provider so playback bubbles and the chat-info Voice
   tab share a single active player. Lazily fetches + decrypts the blob on
   first play (reusing the existing download flow) and caches it locally.

### Recording UX (composer)

The composer already has a `composer-mic` button (currently affordance-only)
in `app/lib/conversation/conversation_page.dart`. Press-and-hold starts
recording and swaps the composer for a recording overlay:

- Red dot + running mm:ss timer.
- Live waveform driven by the amplitude stream.
- "‹ slide to cancel" hint.
- A lock chevron above the mic.

Gestures:
- **Release (unlocked)** → stop and **send immediately**. Voice memos bypass
  the photo staging tray, matching Telegram.
- **Slide left** past a threshold → discard (no send).
- **Slide up to the lock** → hands-free recording; the mic morphs to a stop
  button and a send button appears. Tap stop to finish review, tap send to
  send.

iOS microphone permission is requested on first record;
`NSMicrophoneUsageDescription` is added to `app/ios/Runner/Info.plist`.

### Send / download flow

Sending reuses the existing attachment pipeline
(`app/lib/attachment/attachment_upload.dart`, `file_crypto.dart`):

1. Stop recording → read the `.m4a` bytes.
2. Encrypt with a fresh per-file XChaCha20-Poly1305 key.
3. `RequestUpload` → presigned PUT → upload raw ciphertext to R2/MinIO.
4. Build `AttachmentDescriptor` (mime, durationMs, size, blobKey, key, nonce,
   `waveform`).
5. Wrap in `AudioContent` and fan-out send via the normal encrypted-message
   path.

Download/playback reuses the existing request-download → presigned GET → in-
memory decrypt flow, triggered lazily on first play.

### Playback bubble (`audio/audio_bubble.dart`)

Renders an `AudioContent` message: play/pause button, waveform bars with a
progress fill, drag-to-scrub seek, elapsed/total time, and a tap-to-cycle
speed badge. Because it's a normal message row, reactions, unsend, and read
receipts all work unchanged.

### Chat-info Voice tab

In `app/lib/conversation/chat_info_page.dart`, replace the "Voice messages are
coming soon" placeholder with a reverse-chronological list of audio messages
(mini-waveform + play/pause + duration + date), driven by the shared playback
controller. Change the Media grid filter from `attachment != null` to
`attachment != null && !isAudio` so voice memos don't appear as broken image
tiles.

## Error handling & edge cases

- **Send failure** → existing `failed` `SendStatus` and retry path
  (`MessageStore`), unchanged.
- **Recording interrupted** (incoming call, app backgrounded): unlocked
  recording is discarded; locked recording is kept as a reviewable draft.
- **Scroll away mid-playback** → playback continues; starting another memo
  pauses the first (single-active-player invariant).
- **Permission denied** → show a prompt directing the user to Settings; no
  recording starts.

## Testing (TDD)

Pure-logic and state-machine tests first, then widget tests:

- `waveform.dart`: downsampling produces exactly 64 buckets; normalization
  bounds; empty/short input handling.
- `AudioContent` encode/decode round-trip; descriptor serialization with and
  without `waveform`; backward-compatible decode of unknown kinds.
- `recorder_controller.dart`: state transitions (idle→recording→locked,
  →cancelling, 5:00 auto-stop) with the platform channel mocked.
- `playback_controller.dart`: single-active-player invariant; speed cycling;
  seek clamping.
- Widget tests: audio bubble play/scrub interaction; recording-overlay gesture
  states (cancel threshold, lock threshold).

Audio capture/playback platform plugins are mocked in tests; the pure logic and
controller state machines carry the coverage.

## Files touched

New:
- `app/lib/audio/waveform.dart`
- `app/lib/audio/recorder_controller.dart`
- `app/lib/audio/playback_controller.dart`
- `app/lib/conversation/audio_bubble.dart`
- recording-overlay widget (in composer or its own file under `conversation/`)

Modified:
- `app/lib/conversation/message_content.dart` — add `AudioContent`.
- `app/lib/attachment/attachment_descriptor.dart` — add `waveform` field.
- `app/lib/conversation/conversation_page.dart` — wire mic press-and-hold,
  recording overlay; render `AudioContent` via `audio_bubble`.
- `app/lib/screens/inbox/home_screen.dart` — send path for recorded audio.
- `app/lib/conversation/chat_info_page.dart` — fill Voice tab, exclude audio
  from Media grid.
- `app/ios/Runner/Info.plist` — `NSMicrophoneUsageDescription`.
- `app/pubspec.yaml` — add `record`, `just_audio`.

Backend: **none.**
