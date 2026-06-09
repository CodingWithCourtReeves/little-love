# LittleLove

A private messenger for couples. End-to-end encrypted, hosted by a small couple. AI familiars run on hardware *you* own — no cloud AI providers, ever.

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

## Releases

Tags matching `v*` (e.g., `v0.1.0-day1a`) trigger `.github/workflows/release.yml`, which builds:

- A container image to `ghcr.io/codingwithcourtreeves/littlelove-api:<tag>` (deployed to Railway by `deploy.yml`).
- `LittleLove-<version>.dmg` (macOS).
- `LittleLove-<version>.msi` (Windows).

All three attach to the GitHub Release. First launch warns about unsigned binaries — right-click → Open on macOS, "More info" → "Run anyway" on Windows. Signing is deferred to public launch.

## Docs

- `docs/positioning.md` — product voice (read before writing any user-facing copy)
- `docs/superpowers/specs/2026-06-09-littlelove-design.md` — Phase 1 design (full product)
- `docs/superpowers/specs/2026-06-09-littlelove-day1-design.md` — Day-1 design (the vertical slice being implemented now)
- `docs/superpowers/plans/2026-06-09-littlelove-day1-plan.md` — this plan
- `docs/mocks/` — desktop UI mocks with theme switcher
