# LittleLove

A private messenger for couples. One-to-one with your partner, organized into channels, end-to-end encrypted throughout. No AI, no third parties — just the two of you.

On the roadmap, all end-to-end encrypted: file uploads (photo/video), voice memos, voice calls, and FaceTime-style video.

> **Day-1 alpha**: Court and Kaitlyn are the only users; the code is intentionally throwaway in the places that matter (symmetric encryption with a pre-shared key, no signup flow, no client persistence). The Phase 1 design at `docs/superpowers/specs/2026-06-09-littlelove-design.md` is the real product; Day-1 exists to prove the wire.

## Local dev

Requires: Docker Desktop (or Docker + Compose), Rust 1.88+, Flutter 3.44+ with macOS or Windows desktop enabled.

To try the app end-to-end with both Court and Kaitlyn on one Mac:

```sh
./scripts/dev-up.sh            # api + postgres, in this worktree's namespace
./scripts/demo.sh court        # window 1: real ~/.littlelove/
./scripts/demo.sh kaitlyn      # window 2: fake $HOME under .dev/kaitlyn-home/
./scripts/dev-down.sh
```

`demo.sh` generates a 32-byte shared key on first run (`.dev.demo.key`, gitignored), reuses it on subsequent runs, writes a matching `config.toml` for the named user, and execs `flutter run -d macos` under the right `HOME`.

The dev scripts are **worktree-aware**: each `git worktree` you check out runs on its own ports and Postgres volume, derived deterministically from the worktree directory name. Two worktrees can run simultaneously without conflict.

### Testing attachments locally (MinIO)

E2EE attachments upload encrypted blobs to Cloudflare R2 via presigned URLs. To
exercise the full send → upload → download → decrypt loop offline (no Cloudflare
account), use the bundled MinIO (an S3-compatible store; R2 presigning is just
S3 SigV4):

```sh
./scripts/dev-attachments.sh   # api + postgres + minio, bucket auto-created
./scripts/demo.sh court        # window 1
./scripts/demo.sh kaitlyn      # window 2
```

Pair the two clients, then tap the composer **+** to send a photo. The MinIO
console is at <http://localhost:9001> (`littlelove` / `devsecret123`).

The server only *signs* URLs (it never connects to the store), so it signs the
client-facing `http://localhost:9000`; `docker-compose.minio.yml` sets the
matching `R2_*` env. Sanity-check the server's presigner against MinIO with:

```sh
cargo test -p littlelove-api --test minio_roundtrip -- --ignored
```

Caveats: the macOS demo client handles **photos** only — video poster frames
(`video_thumbnail`) need an iOS device/simulator, and the 500 MiB memory check
needs a physical device.

## Releases

Tags matching `v*` (e.g., `v0.1.0-day1a`) trigger `.github/workflows/release.yml`, which builds:

- A container image to `docker.io/codingwithcourt/littlelove-api:<tag>` (deployed to Railway by `deploy.yml`).
- `LittleLove-<version>.dmg` (macOS).
- `LittleLove-<version>.msi` (Windows).

All three attach to the GitHub Release. First launch warns about unsigned binaries — right-click → Open on macOS, "More info" → "Run anyway" on Windows. Signing is deferred to public launch.

## Docs

- `docs/positioning.md` — product voice (read before writing any user-facing copy)
- `docs/superpowers/specs/2026-06-09-littlelove-design.md` — Phase 1 design (full product)
- `docs/superpowers/specs/2026-06-09-littlelove-day1-design.md` — Day-1 design (the vertical slice being implemented now)
- `docs/superpowers/plans/2026-06-09-littlelove-day1-plan.md` — this plan
- `docs/mocks/` — desktop UI mocks with theme switcher
