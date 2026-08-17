# Reality Connect — public release distribution

Signed artifacts and channel manifests for Reality Connect products, plus the
generic release tooling used to distribute and custody them:

- [`install.sh`](./install.sh) — single-line installer/updater for RC release CLIs
- [`release-secrets.sh`](./release-secrets.sh) — release-secret custody helper
  (Apple Passwords + GitHub Actions secrets)

**This repo contains no secrets.** Release tags (binaries, signatures, channel
manifests) live here as GitHub releases; the tooling below only ever points at
them.

---

## install.sh

One-line install of an RC product CLI, with target detection, checksum
verification, and idempotent updates. POSIX `sh` (works on macOS `sh`, Ubuntu
`dash`, Alpine busybox).

```sh
curl -fsSL https://raw.githubusercontent.com/reality-connect/releases/main/install.sh \
  | sh -s -- --project new-seed --channel beta
```

Re-run the same command later to update (skips when the installed version
already matches; `--force` to reinstall). The `--project` slug selects the
product and names the installed binary; the script is generic across every RC
product. Example for the live new-seed beta:

```
--project new-seed --channel beta      # live beta channel (new-seed-channel-beta/beta.json)
```

### Options

| Flag | Meaning |
|---|---|
| `--project <slug>` | RC product slug (**required**); the CLI installs as this name |
| `--publisher <owner/repo>` | GitHub repo publishing releases (default `reality-connect/releases`) |
| `--channel <name>` | Release lane: `stable`, `beta`, `nightly` (alias: `--lane`) |
| `--bin-dir <dir>` | Install directory (default: `~/.local/bin` when writable, else `/usr/local/bin` with `sudo` when available; musl/Linux defaults to `/usr/local/bin`) |
| `--dry-run` | Print the resolution plan (pointer, version, target, URLs, bin-dir) without downloading or installing |
| `--force` | Reinstall even when the installed version matches |
| `--minisign-pubkey <key-or-file>` | Public key for full `.sig` verification (also `RC_MINISIGN_PUBKEY`) |

### How it works

1. **Detection** — `uname -s`/`-m` → `darwin-aarch64`, `darwin-x86_64`,
   `linux-x86_64-gnu`, `linux-x86_64-musl`. musl is detected via `ldd --version`
   output and the musl loader (`/lib/ld-musl-*`); anything else fails with a
   clear error listing the supported targets.
2. **Pointer** — fetches `<project>-channel-<channel>/<channel>.json` from the
   publisher's `releases/download` (canonical: `https://github.com/<publisher>/releases/download`),
   parses `version` and `cli.<target>` (`url`, `sha256`, `size`) with `sed`/`awk`
   — **no `jq` dependency**.
3. **Integrity** — always verifies the binary against **both** the manifest
   `sha256` and the published `SHA-256SUMS` entry (plus the manifest `size`).
   When a `minisign` binary **and** a public key are available, the artifact
   `.sig` is verified too; otherwise an honest skip note is printed — integrity
   then rests on TLS + the manifest hash (TOFU over TLS).
4. **Install** — atomic `tmp + mv` into the bin dir; prints the installed
   version, next steps, and the channel/`--lane` hint.

Environment (test seam): `RC_RELEASES_BASE_URL` overrides the download base
(used by `tests/run.sh` to serve a mocked release tree via `file://`).

### Publisher contract (what a release must contain)

For each product/channel, publish a GitHub release containing:

- the channel pointer `<slug>-channel-<channel>/<channel>.json`, pretty-printed,
  with `version` and a `cli` object keyed by target (`darwin-aarch64`,
  `darwin-x86_64`, `linux-x86_64-gnu`, `linux-x86_64-musl`, …); each entry has
  `url`, `sha256`, `size`, and an optional `signature` (minisign):
  ```json
  {
    "schemaVersion": 2,
    "channel": "beta",
    "version": "1.0.0-beta.1",
    "cli": {
      "linux-x86_64-gnu": {
        "url": "https://github.com/reality-connect/releases/releases/download/<tag>/cli-linux-x86_64-gnu",
        "sha256": "6c1bb0c1…",
        "size": 101623936
      }
    }
  }
  ```
- the binary itself, plus `SHA-256SUMS` in the same release (coreutils format,
  one entry per artifact) and `SHA-256SUMS.sig`; per-artifact `.sig` files are
  optional (used only when minisign verification is possible).

---

## release-secrets.sh

Custody helper for RC release secrets, generalized from the original
new-seed script — **nothing is hardcoded to a project**; the GitHub repo is
always explicit via `--repo owner/name`. Custody model: Apple Passwords is the
sole recovery copy; GitHub Actions secrets are the only online copies.

```sh
# stage ONE custody item on the clipboard, paste it into Apple Passwords, repeat
release-secrets.sh --repo reality-connect/new-seed vault 'secure NOTE "RC release artifact key"' rc-release-artifact.key

# forward ONE value to a GitHub secret (hidden input, never on disk)
release-secrets.sh --repo reality-connect/new-seed upload RELEASE_PUBLISH_TOKEN

# set the four release-signing secrets from explicit local files (agent-runnable)
release-secrets.sh --repo reality-connect/new-seed upload-signing \
  rc-release-artifact.key rc-release-artifact.pass \
  rc-release-manifest.key rc-release-manifest.pass
```

Guards: `--repo` is validated; `vault` refuses missing/empty files; `upload`
refuses empty input; `upload-signing` refuses missing/empty files and aborts if
any `gh secret set` fails. After everything is in GitHub + Passwords, destroy
the local plaintext copies.

---

## Testing

`tests/run.sh` verifies `install.sh` three ways:

| Mode | What runs |
|---|---|
| `tests/run.sh local` | `sh -n` both scripts + live `--dry-run` against the real new-seed beta pointer |
| `tests/run.sh in-container` | Full mocked suite: detection, channel selection, checksum/SUMS refusals, bin-dir placement, idempotent updates, `--force`, minisign skip note |
| `tests/run.sh docker` | The mocked suite in a docker matrix (default) |

The mocked suite serves a fake channel pointer + `SHA-256SUMS` + binary via
`file://` (no server process, no network inside the container) and asserts the
installer picks the right target per `uname`, honors `--channel` by reading the
pointer manifest, refuses checksum mismatches and tampered SUMS, refuses
unknown flags, installs into the requested bin dir, is idempotent for updates,
and prints the honest minisign skip note.

### Matrix results (2026-08-17)

| Image | Platform | Result |
|---|---|---|
| `ubuntu:24.04` | linux/amd64 (glibc) | **27/27 PASS** — target `linux-x86_64-gnu` |
| `debian:12` | linux/amd64 (glibc) | **27/27 PASS** — target `linux-x86_64-gnu` |
| `alpine:3.21` | linux/amd64 (musl) | **27/27 PASS** — target `linux-x86_64-musl`, default bin-dir `/usr/local/bin` |

Logs: `tests/results/*.log`. Local (macOS, darwin-aarch64): `sh -n` clean for
both scripts; live dry-run against `new-seed-channel-beta/beta.json` resolves
`new-seed 1.0.0-beta.1` → `cli-darwin-aarch64` (sha256
`eff6c80c…280381`), plan-only, exit 0.

Re-run everything after touching `install.sh`:

```sh
tests/run.sh local
tests/run.sh docker
```

## Maintenance

- Channel pointers are TUF-lite signed channel metadata (see `beta.json` /
  `SHA-256SUMS.sig`); `expiresAt` in the pointer is informational for clients.
- Keep the mocked suite in lockstep with the publisher contract above: any new
  field the installer parses must appear in `tests/run.sh`'s mock pointers.
- The installer intentionally avoids `jq`, `curl | jq`, and any eval of remote
  content — only quoted manifest fields are used literally.
