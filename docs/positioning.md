# LittleLove — Positioning

This is the source of truth for product voice. Anywhere we write user-facing copy — onboarding text, marketing site, App Store / GitHub Release descriptions, in-app strings — start here. Implementation specs and plans should defer to this document on tone and framing.

## Product framing (2026-06-16)

LittleLove is a **couples-first messenger**: one-to-one with your partner, organized into channels, end-to-end encrypted throughout. Built and hosted by a small couple who use it themselves. No AI, no third parties — just the two of you.

The roadmap extends the same private, two-person experience to richer media, all end-to-end encrypted: file uploads (photo and video), voice memos, voice calls, and FaceTime-style video.

## Positioning (refined)

**LittleLove is an end-to-end encrypted messenger for couples, built by two people who use it themselves.** Conversations live only on devices you own. The server holds ciphertext it cannot read.

**One partner, many channels.** The app is built around a single relationship. Channels let the two of you organize that relationship — "travel," "daily life," "the house" — without it ever becoming a group app.

**No third parties — ever.** There is no AI, no analytics vendor, and no cloud provider in the message path. This is structural, not policy: if there is no code path that sends your messages anywhere but your partner's device, there is nothing for anyone else to read or train on.

**More ways to be together, same privacy.** Photos and video, voice memos, voice calls, and FaceTime-style video are on the roadmap — each one end-to-end encrypted from the start, never bolted on after the fact.

## Key claims and how we'd defend them

| Claim | Defense |
|---|---|
| "End-to-end encrypted; server cannot read messages" | Per-recipient ciphertext addressed to device keys we never possess; the server stores and fans out opaque blobs. Published in the design spec. |
| "Hosted by a small couple" | Literally — Court and Kaitlyn run it. The Railway billing has their name on it. Founder-operated, not VC-backed. |
| "No third parties in the message path" | There is no analytics SDK, no cloud AI provider, and no external service that receives plaintext. Messages travel client → server (ciphertext) → client. |
| "Couples-first, not a group app" | The product centers a single partner link (monogamy enforced server-side). Channels are shared rooms for the two of you, not multi-party group chat. |
| "Future media stays end-to-end encrypted" | File uploads, voice memos, and calls are designed encrypted-first; we add the capability only once the encrypted transport for it exists. |

## Voice — DO

- **Speak to one couple, not a market.** "You and your partner." Not "users," not "customers."
- **Be specific about what we won't do.** "No third parties in the message path" beats "privacy-focused."
- **Quietly proud, not preachy.** State the encryption guarantee once, then talk about the experience.
- **Show your hands.** "Hosted by a small couple" beats "founder-led startup."
- **Anchor every privacy claim in a structural fact.** Not "we don't sell your data" — "the code path doesn't exist."

## Voice — DON'T

- **Don't compare to Signal, WhatsApp, iMessage by name in marketing.** Be your own thing. (Internal docs can compare freely.)
- **Don't market group chat.** Channels exist to organize one couple's conversation, not to host crowds.
- **Don't apologize for being small.** Small couple > startup. Lean into it.
- **Don't use words like "secure," "private," "encrypted" without immediately backing them up.** Vague safety claims read as bluster. Specific structural claims read as integrity.

## Anti-positioning — what we are NOT

- Not a family chat app.
- Not a dating app.
- Not a group chat app.
- Not a "private alternative to [X]."
- Not a productivity tool with chat bolted on.

## One-liner candidates (for marketing site / app store)

These all carry the same claims; pick whichever lands best when we write the marketing site:

- *Private messaging for two. Channels to organize it, encryption to protect it.*
- *An end-to-end encrypted messenger for couples, hosted by a couple.*
- *Two people, one chat, no one else — by design.*
- *Your relationship, organized into channels and readable only by the two of you.*

We don't pick the final one here. We pick it when we write the marketing site, after the app is real and we know the tone.
