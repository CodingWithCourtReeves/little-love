# LittleLove — Positioning

This is the source of truth for product voice. Anywhere we write user-facing copy — onboarding text, marketing site, App Store / GitHub Release descriptions, in-app strings — start here. Implementation specs and plans should defer to this document on tone and framing.

## Founder's words (verbatim, 2026-06-09)

> An app built with encryption and hosted by a small couple. With a concept of bring your own AI model. We reject any cloud AI models so that Anthropic, OpenAI cannot train on user data. Our system supports character cards by default so out of the gate we support 2,000,000+ models.

These are Court's words and they capture the product's soul. Refinements below preserve every claim and make each one defensible.

## Positioning (refined)

**LittleLove is an end-to-end encrypted messenger for couples, built by two people who use it themselves.** Conversations live only on devices you own. The server holds ciphertext it cannot read.

**Bring your own AI.** Want an AI familiar in your chat? Run it on your own hardware. LittleLove supports any model you can run through Ollama or a local OpenAI-compatible server — that's the entire open-weight model ecosystem (HuggingFace, llama.cpp, vLLM, LM Studio).

**No cloud AI providers — ever.** We do not integrate with OpenAI, Anthropic, OpenRouter, or any cloud LLM. Not as a default. Not as an option you can enable. This is structural, not policy: if there is no code path that sends your messages to a third-party LLM, there is no way for those companies to train on your conversations.

**Character cards out of the gate.** Every AI familiar is shaped by a character card — a persona you write or import. We support the open Character Card v2 PNG format from day one, which gives you free access to the existing community library of personas without a vendor lock-in.

## Key claims and how we'd defend them

| Claim | Defense |
|---|---|
| "End-to-end encrypted; server cannot read messages" | MLS (RFC 9420) protocol. Server holds opaque ciphertext blobs, signed by client device keys we never possess. Published in the design spec §10.4. |
| "Hosted by a small couple" | Literally — Court and Kaitlyn run it. The Railway billing has their name on it. Founder-operated, not VC-backed. |
| "Bring your own AI" | The `LocalModelProvider` trait + Ollama / OpenAI-compatible adapters (design spec §9.4). User points the bot host at any LAN endpoint that speaks one of two well-known APIs. |
| "We reject cloud AI providers" | No `OpenAIProvider`, `AnthropicProvider`, or `CloudProvider` of any kind exists in the codebase. The trait implementations check that the configured endpoint resolves to a private IP range and refuse to connect to public ones. (Documented in design spec §9.4 as a non-goal.) |
| "2,000,000+ models" | The combined open-weight model ecosystem reachable through Ollama, LM Studio, llama.cpp, and vLLM exceeds two million distinct models on HuggingFace as of 2026. We support the *runtimes*, which gives users access to that universe; we don't ship the models themselves. **Phrase it as "any open-weight model" rather than a specific count when the audience is technical.** Use the count when it's marketing copy. |
| "Character cards by default" | Character Card v2 PNG import in Phase 1.5 of the design spec (note: tied to spec §9.1 character-card data structure that ships in Phase 1). Marketing claim and spec are aligned: cards are first-class from day one; community PNG import lands shortly after. |

## Voice — DO

- **Speak to one couple, not a market.** "You and your partner." "Your familiar." Not "users," not "customers."
- **Be specific about what we won't do.** "No cloud AI providers — ever" beats "privacy-focused."
- **Quietly proud, not preachy.** State the encryption guarantee once, then talk about the experience.
- **Show your hands.** "Hosted by a small couple" beats "founder-led startup."
- **Anchor every privacy claim in a structural fact.** Not "we don't sell your data" — "the code path doesn't exist."

## Voice — DON'T

- **Don't compare to Signal, WhatsApp, iMessage by name in marketing.** Be your own thing. (Internal docs can compare freely.)
- **Don't market group chat.** Multi-party rooms exist because MLS supports them; the product is for couples. (See `project_littlelove.md` memory.)
- **Don't say "AI-powered."** The AI is a *familiar* you brought along, not a feature of the app.
- **Don't apologize for being small.** Small couple > startup. Lean into it.
- **Don't use words like "secure," "private," "encrypted" without immediately backing them up.** Vague safety claims read as bluster. Specific structural claims read as integrity.

## Anti-positioning — what we are NOT

- Not a family chat app.
- Not a dating app.
- Not a "private alternative to [X]."
- Not a productivity tool with chat bolted on.
- Not a place to "talk to an AI" — the AI is in *your* conversation, not the other way around.

## One-liner candidates (for marketing site / app store)

These all carry the same claims; pick whichever lands best when we write the marketing site:

- *Private messaging for couples. Bring your own AI familiar — never the cloud's.*
- *An end-to-end encrypted messenger for two, hosted by a couple of two.*
- *LittleLove: chats only you can read, with an AI that runs on your own hardware.*
- *Two people, one chat, no cloud AI. Bring your own model.*

We don't pick the final one here. We pick it when we write the marketing site, after the app is real and we know the tone.
