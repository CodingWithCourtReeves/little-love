# littlelove-bot

A 1-on-1 AI companion that lives in its own LittleLove room with you. The bot is just another paired account from the server's perspective — same handshake, same end-to-end encryption, same room-key derivation. The only thing different is that instead of a human typing replies, a local LLM does.

> **No cloud AI, ever.** The bot only talks to an LLM you run on hardware you own (LM Studio, llama-server, Ollama, anything OpenAI-compatible). The address guard refuses non-private LLM endpoints at startup. Your messages never leave your machine for inference.

## How it fits

```
[ Your phone ]  ──WSS──>  [ LittleLove server ]  <──WSS──  [ littlelove-bot ]
                              (only sees ciphertext)              │
                                                                  │ HTTP
                                                                  ▼
                                                       [ Local LLM on 127.0.0.1 ]
```

The bot pairs into a separate room from your couple chat. Your room with your partner stays untouched and bot-free; the bot's room is a private side-channel between you and the AI.

## Prerequisites

- **A LittleLove account on your phone.** Use the iOS/desktop app to sign up first.
- **A local OpenAI-compatible LLM endpoint.** Easiest: [LM Studio](https://lmstudio.ai) — install, load a model, click **Start Server** in the Developer tab (default `http://127.0.0.1:1234/v1`).
- **A chat-tuned model.** For roleplay personas, anything Mistral Nemo 12B or Llama 3.1 8B-based works. [chub.ai](https://chub.ai) is the de-facto library for character cards.
- **Rust 1.88+** if building from source. (Or grab a release binary — see Releases below.)
- **macOS 12+, Windows 10+, or Linux x86_64.**

## Quick start

```sh
# 1. Build (or download a release binary into ./target/release/)
cargo build -p littlelove-bot --release

# 2. On your phone: open LittleLove → "Pair with someone" → "Show invite code".
#    Read the four-word code.

# 3. Pair the bot. This signs the bot up and consumes the invite.
./target/release/littlelove-bot pair \
  --server wss://YOUR-LITTLELOVE-SERVER \
  --code "word1-word2-word3-word4" \
  --username lovebot

# 4. Run the bot. It subscribes to the room and replies to inbound messages.
./target/release/littlelove-bot run \
  --server wss://YOUR-LITTLELOVE-SERVER \
  --llm-url http://127.0.0.1:1234/v1 \
  --model your-loaded-model-id
```

A new room will appear in your phone's inbox. Tap into it and send a message — the bot will decrypt → call your local LLM → encrypt the reply → ship it back.

## Giving the bot a personality

The bot accepts standard [Character Card v2 / v3](https://github.com/malfoyslastname/character-card-spec-v2) PNGs — the same format used by SillyTavern and most roleplay tools.

```sh
./target/release/littlelove-bot run \
  --server wss://YOUR-LITTLELOVE-SERVER \
  --llm-url http://127.0.0.1:1234/v1 \
  --model your-model-id \
  --character-card /path/to/card.png
```

Get cards from:
- **[chub.ai](https://chub.ai/characters)** — large library, free downloads
- **[character-tavern.com](https://www.character-tavern.com/)** — curated set
- Or build your own with SillyTavern's editor

If no card is provided, the bot uses a neutral assistant persona. You can also pass `--system-prompt-file path/to/prompt.txt` for plain-text personas.

## Configuration

All flags can be set via env var. See `littlelove-bot run --help` for the full list. Common ones:

| Flag | Env | Default | Notes |
| --- | --- | --- | --- |
| `--server` | `LITTLELOVE_BOT_SERVER` | (required) | `wss://...` of your LittleLove server (no path) |
| `--llm-url` | `LITTLELOVE_BOT_LLM_URL` | `http://localhost:8080/v1` | Must be loopback / private IP |
| `--model` | `LITTLELOVE_BOT_MODEL` | `local-model` | Exact model ID your LLM server reports |
| `--temperature` | `LITTLELOVE_BOT_TEMPERATURE` | `0.8` | Persona warmth |
| `--max-tokens` | `LITTLELOVE_BOT_MAX_TOKENS` | `512` | Reply length cap |
| `--history` | `LITTLELOVE_BOT_HISTORY` | `20` | How many past turns to send to the LLM |
| `--character-card` | — | — | CCv2/v3 PNG (mutually exclusive with `--system-prompt-file`) |

## Where the bot's identity lives

After `pair`, the bot saves its keypair + recovery phrase to an OS-appropriate location with `0600` permissions:

- **macOS**: `~/Library/Application Support/dev.littlelove.littlelove-bot/identity.json`
- **Linux**: `~/.local/share/dev.littlelove.littlelove-bot/identity.json`
- **Windows**: `%APPDATA%\dev.littlelove\littlelove-bot\identity.json`

Back this file up if you want to be able to restore the bot's account later. Without it, you'll need to re-pair with a fresh invite (and the bot's previous messages stay on the server as ciphertext only it could decrypt).

To see the bot's pubkey fingerprints without exposing secrets:

```sh
./target/release/littlelove-bot show-identity
```

## Known limitations (v0.2)

- **No auto-reconnect.** If the WSS connection drops (network blip, ngrok timeout, server restart), the bot exits. Wrap it in a shell loop or a systemd/launchd service if you want it persistent.
- **No long-term memory.** The bot only sees the last `--history` messages. Anything older is forgotten. (This is on the v0.3 roadmap.)
- **One room only.** The bot pairs into exactly one room. Re-running `pair` with `--force` replaces its identity.
- **Manual setup.** The whole flow assumes you're comfortable in a terminal. A GUI wrapper is planned — see [issue tracker](https://github.com/CodingWithCourtReeves/little-love/issues) for the discussion.

## Troubleshooting

- **`signup failed 404`** — your `--server` URL is wrong. Don't include `/ws` at the end; the bot appends paths itself.
- **`refusing non-private LLM endpoint`** — `--llm-url` must be loopback (`127.0.0.1`, `::1`), RFC1918 (`192.168/16`, `10/8`, `172.16/12`), link-local, CGNAT, or unique-local IPv6. This is the cloud-AI guard.
- **`no ccv3 or chara text chunk in PNG`** — your character card isn't a CCv2/v3 PNG. Common cause: you saved a screenshot instead of the actual card. Re-download from chub.ai.
- **`WebSocket protocol error: Connection reset`** — the server or your tunnel dropped you. No auto-reconnect yet (see Limitations).
- **Bot replies are off-topic / hallucinated** — your LLM is too small or your character card is contradictory. Try Llama 3.1 8B Stheno or a Mistral Nemo 12B finetune; both perform well at this size.

## Building from source

```sh
git clone https://github.com/CodingWithCourtReeves/little-love
cd little-love
cargo build -p littlelove-bot --release
# Binary lands at target/release/littlelove-bot
```

CI ships matrix builds for macOS arm64 + x86_64, Windows x86_64, and Linux x86_64 on every release tag.
