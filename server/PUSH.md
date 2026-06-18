# APNs push notifications

When a partner sends a message and the recipient has **no live WebSocket
session**, the server delivers a content-free, brand-styled iOS push that — on
tap — opens the specific room. Push is reached directly from Rust via the `a2`
crate with token auth (`.p8`). No Firebase, no Google.

The notification is deliberately generic and carries no message content (E2EE:
the server only ever sees ciphertext):

- title: `Little Love`
- body: `💜 Your partner sent you a message`

The only payload metadata is the opaque `room_id` (custom data, for the tap
deep-link). The push sets `mutable-content: 1` so the on-device Notification
Service Extension can attach the current palette's artwork.

## Server configuration

Push is **optional**. If any of the required `APNS_*` vars are unset, the server
runs exactly as before with push disabled (boot logs `APNS_* env unset; push
notifications disabled`). Local dev and the test suite never need APNs keys.

| Variable        | Required | Meaning                                            |
| --------------- | -------- | -------------------------------------------------- |
| `APNS_KEY_P8`   | yes      | Contents of the `.p8` auth key (PEM), not a path   |
| `APNS_KEY_ID`   | yes      | Key id from the Apple Developer portal             |
| `APNS_TEAM_ID`  | yes      | Apple team id — `9PVUX2535W`                        |
| `APNS_TOPIC`    | yes      | APNs topic = the app bundle id — `dev.littlelove.littlelove` |
| `APNS_ENV`      | no       | `sandbox` (default) or `production`                |

`APNS_KEY_P8` holds the key contents directly (a single multi-line secret) so it
travels as one deploy secret rather than a mounted file. The sender builds one
HTTP/2 client per environment, so a couple's mixed sandbox/production device
tokens both work from a single configured key.

When configured correctly, the boot log will **not** contain "APNS_* env
unset"; an init failure logs `APNs sender init failed; push disabled: <err>`.

### Local dev: `.secrets.env`

For on-device testing you don't export these by hand each run. `scripts/dev-phones.sh`
auto-sources a gitignored `.secrets.env` at the repo root if present. Copy the
committed example values into it once:

```bash
# .secrets.env (gitignored — never committed)
export APNS_KEY_P8="$(cat "$HOME/.little-love-secrets/AuthKey_XXXXXXXXXX.p8")"
export APNS_KEY_ID="XXXXXXXXXX"
export APNS_TEAM_ID="9PVUX2535W"
export APNS_TOPIC="dev.littlelove.littlelove"
export APNS_ENV="sandbox"
```

Keep the `.p8` itself outside the repo (e.g. `~/.little-love-secrets/`); the file
only reads its contents. `dev-phones.sh` prints `APNs push: configured …` on
startup when it loaded successfully. Absent file → push simply stays disabled.

## Token hygiene

APNs reports a permanently-dead token via a 410 `Unregistered`, or a 400
`BadDeviceToken` / `DeviceTokenNotForTopic`. On any of these the server deletes
that token row (`device_push_tokens`). Other non-2xx responses are treated as
transient and the token is kept.

## Manual on-device verification matrix

Push behavior is integration-level and can only be confirmed on physical
devices. Deploy the server with the `APNS_*` sandbox key set, then build to two
phones with `./scripts/ios-deploy.sh --server <dev-url>` (preserves the keychain
identity — see `CLAUDE.md`). Grant the permission prompt when it appears (after
pairing / entering the inbox). Confirm each:

- [ ] A (foreground) sends → B **backgrounded** → B gets the banner with the
      palette artwork attached.
- [ ] B **foregrounded in the room** → A sends → **no banner** (in-app only).
- [ ] B **force-killed** → A sends → B still gets the banner.
- [ ] Tap the banner from **backgrounded** B → opens the correct room at the
      newest message.
- [ ] Tap the banner from **killed** B (cold launch) → app launches and opens
      the correct room.
- [ ] No message text ever appears in any notification.
