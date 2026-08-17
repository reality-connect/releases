#!/bin/sh
# install.sh — single-line installer/updater for Reality Connect release CLIs.
#
#   curl -fsSL https://raw.githubusercontent.com/reality-connect/releases/main/install.sh \
#     | sh -s -- --project new-seed [--publisher owner/repo] [--channel beta] \
#                [--bin-dir DIR] [--dry-run] [--force] [--minisign-pubkey KEY]
#
# --project  slug of the RC product (required; the CLI installs as this name)
# --publisher  GitHub owner/repo publishing releases (default reality-connect/releases)
# --channel  stable | beta | nightly (alias: --lane)
# --bin-dir  install directory (default: ~/.local/bin if writable, else
#            /usr/local/bin with sudo when available; musl/linux defaults to /usr/local/bin)
# --dry-run  print the resolution plan without downloading or installing
# --force    reinstall even when the installed version already matches
# --minisign-pubkey  minisign public key (file or inline); enables full .sig verification
#
# Detection: uname -s/-m -> darwin-aarch64, darwin-x86_64, linux-x86_64-gnu,
# linux-x86_64-musl (musl detected via ldd / loader). Unsupported -> error listing targets.
#
# Integrity: the channel pointer is fetched over TLS, then the binary is always
# checked against BOTH the manifest sha256 and the published SHA-256SUMS entry.
# When a minisign binary AND a public key are available, the artifact .sig is
# verified too; otherwise an honest skip note is printed (TOFU over TLS).
#
# Environment (test seam): RC_RELEASES_BASE_URL overrides the download base
# (default https://github.com/<publisher>/releases/download). RC_MINISIGN_PUBKEY
# is the default for --minisign-pubkey.
set -eu

PROJECT=""
PUBLISHER="reality-connect/releases"
CHANNEL="stable"
BIN_DIR=""
BIN_CMD=""
FORCE=0
DRY_RUN=0
MINISIGN_PUBKEY="${RC_MINISIGN_PUBKEY:-}"

usage() {
  echo "usage: install.sh --project <slug> [--publisher owner/repo] [--channel stable|beta|nightly] [--bin-dir DIR] [--dry-run] [--force] [--minisign-pubkey KEY]"
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

die() { echo "error: $*" >&2; exit 1; }

# --- arg parsing -----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; PROJECT="$2"; shift 2 ;;
    --publisher) [ $# -ge 2 ] || usage; PUBLISHER="$2"; shift 2 ;;
    --channel|--lane) [ $# -ge 2 ] || usage; CHANNEL="$2"; shift 2 ;;
    --bin-dir) [ $# -ge 2 ] || usage; BIN_DIR="$2"; shift 2 ;;
    --bin-name) [ $# -ge 2 ] || usage; BIN_CMD="$2"; shift 2 ;;
    --minisign-pubkey) [ $# -ge 2 ] || usage; MINISIGN_PUBKEY="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "install.sh: unknown option: $1" >&2; usage ;;
  esac
done

[ -n "$PROJECT" ] || { echo "install.sh: --project is required" >&2; usage; }
case "$PROJECT" in
  */*|*[!A-Za-z0-9._-]*) die "invalid --project slug: $PROJECT" ;;
esac
case "$PUBLISHER" in
  */*) [ "$(printf '%s' "$PUBLISHER" | tr -cd '/')" = "/" ] || die "invalid --publisher (want owner/repo): $PUBLISHER" ;;
  *) die "invalid --publisher (want owner/repo): $PUBLISHER" ;;
esac
case "$CHANNEL" in
  ""|*[!A-Za-z0-9._-]*) die "invalid --channel: $CHANNEL (use e.g. stable|beta|nightly)" ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v uname >/dev/null 2>&1 || die "uname is required"

# --- target detection ------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
SUPPORTED="darwin-aarch64, darwin-x86_64, linux-x86_64-gnu, linux-x86_64-musl"
case "$OS" in
  Darwin) TARGET_OS="darwin" ;;
  Linux) TARGET_OS="linux" ;;
  *) die "unsupported OS: $OS (supported targets: $SUPPORTED)" ;;
esac
case "$ARCH" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64|amd64) ARCH="x86_64" ;;
  *) die "unsupported architecture: $ARCH (supported targets: $SUPPORTED)" ;;
esac
TARGET="$TARGET_OS-$ARCH"
if [ "$TARGET" = "linux-x86_64" ]; then
  IS_MUSL=0
  if ldd --version 2>/dev/null | grep -qi musl; then IS_MUSL=1; fi
  if [ "$IS_MUSL" = 0 ] && command -v ldd >/dev/null 2>&1 \
     && ldd /bin/sh 2>/dev/null | grep -qi 'ld-musl'; then IS_MUSL=1; fi
  if [ "$IS_MUSL" = 0 ]; then
    for l in /lib/ld-musl-* /usr/lib/ld-musl-*; do
      [ -e "$l" ] && IS_MUSL=1 && break
    done
  fi
  if [ "$IS_MUSL" = 1 ]; then TARGET="linux-x86_64-musl"; else TARGET="linux-x86_64-gnu"; fi
fi
case "$TARGET" in
  darwin-aarch64|darwin-x86_64|linux-x86_64-gnu|linux-x86_64-musl) ;;
  *) die "unsupported target: $TARGET (supported targets: $SUPPORTED)" ;;
esac

# The installed command name: --bin-name wins, else the project slug.
BIN_CMD="${BIN_CMD:-$PROJECT}"

# --- bin dir resolution ----------------------------------------------------
SUDO=""
if [ -n "$BIN_DIR" ]; then
  # An explicit --bin-dir may not exist yet — create it (no sudo) before deciding
  # writability, so a fresh user-owned dir never takes the sudo path.
  mkdir -p "$BIN_DIR" 2>/dev/null || true
  if [ ! -w "$BIN_DIR" ]; then
    if [ "$(id -u)" = 0 ]; then
      : # root creates it at install time
    elif command -v sudo >/dev/null 2>&1; then
      SUDO=sudo
    else
      die "bin dir $BIN_DIR is not writable and sudo is unavailable; pass --bin-dir"
    fi
  fi
elif [ "$TARGET" = "linux-x86_64-musl" ]; then
  BIN_DIR=/usr/local/bin
else
  if { [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; } \
     || { mkdir -p "$HOME/.local/bin" 2>/dev/null && [ -w "$HOME/.local/bin" ]; }; then
    BIN_DIR="$HOME/.local/bin"
  elif [ "$(id -u)" = 0 ]; then
    BIN_DIR=/usr/local/bin
  elif command -v sudo >/dev/null 2>&1; then
    BIN_DIR=/usr/local/bin; SUDO=sudo
  elif [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
  else
    die "cannot determine a writable bin dir; pass --bin-dir"
  fi
fi

# --- fetch + parse channel pointer -----------------------------------------
BASE="${RC_RELEASES_BASE_URL:-https://github.com/$PUBLISHER/releases/download}"
POINTER_URL="$BASE/$PROJECT-channel-$CHANNEL/$CHANNEL.json"
echo "install.sh: target: $TARGET  channel: $CHANNEL  project: $PROJECT"
echo "install.sh: fetching pointer: $POINTER_URL"
POINTER="$(curl -fsSL "$POINTER_URL" 2>/dev/null)" \
  || die "failed to fetch channel pointer: $POINTER_URL (is the '$CHANNEL' channel published?)"

version="$(printf '%s\n' "$POINTER" | sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
entry="$(printf '%s\n' "$POINTER" | awk -v t="$TARGET" '
  $0 ~ "\"" t "\"[[:space:]]*:[[:space:]]*\\{" { capturing=1 }
  capturing {
    buf = buf $0 "\n"
    if ($0 ~ /^[[:space:]]*}[,]*[[:space:]]*$/) { printf "%s", buf; exit }
  }')"
url="$(printf '%s\n' "$entry" | sed -n 's/^[[:space:]]*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
sha256="$(printf '%s\n' "$entry" | sed -n 's/^[[:space:]]*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
size="$(printf '%s\n' "$entry" | sed -n 's/^[[:space:]]*"size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"

[ -n "$version" ] || die "malformed channel pointer: no \"version\" field in $POINTER_URL"
[ -n "$url" ] || die "no cli entry for target '$TARGET' in $POINTER_URL"
[ -n "$sha256" ] || die "no sha256 for target '$TARGET' in $POINTER_URL"
[ "${#sha256}" -eq 64 ] || die "malformed sha256 for target '$TARGET' in $POINTER_URL"
case "$url" in
  https://*|http://*|file://*) ;;
  *) die "unsafe binary URL scheme in pointer: $url" ;;
esac

BIN_NAME="$(basename "$url")"
SUMS_URL="${url%/*}/SHA-256SUMS"

# --- update check ----------------------------------------------------------
CURRENT=""
if [ "$FORCE" = 0 ] && [ -x "$BIN_DIR/$BIN_CMD" ]; then
  if out="$("$BIN_DIR/$BIN_CMD" version 2>/dev/null)"; then
    CURRENT="$(printf '%s\n' "$out" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  fi
fi
if [ -n "$CURRENT" ] && [ "$CURRENT" = "$version" ]; then
  echo "install.sh: already up to date ($BIN_CMD $version at $BIN_DIR/$BIN_CMD)"
  [ "$DRY_RUN" = 1 ] && exit 0
  exit 0
fi

# --- dry-run ---------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "install.sh: dry-run — would install:"
  echo "  project : $PROJECT"
  echo "  version : $version  (channel $CHANNEL)"
  echo "  target  : $TARGET"
  echo "  binary  : $url"
  echo "  sha256  : $sha256"
  echo "  size    : ${size:-unknown}"
  echo "  sums    : $SUMS_URL"
  echo "  bin-dir : $BIN_DIR${SUDO:+ (via sudo)}"
  if [ -n "$CURRENT" ]; then
    echo "  note    : current installed version $CURRENT differs — would update"
  else
    echo "  note    : no existing $PROJECT binary — fresh install"
  fi
  exit 0
fi

# --- download + verify -----------------------------------------------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "install.sh: downloading $url"
curl -fsSL "$url" -o "$tmp/$BIN_NAME" || die "failed to download binary: $url"
curl -fsSL "$SUMS_URL" -o "$tmp/SHA-256SUMS" || die "failed to download $SUMS_URL"

if [ -n "$size" ]; then
  actual_size="$(wc -c < "$tmp/$BIN_NAME" | tr -d '[:space:]')"  # BSD wc pads numbers
  [ "$actual_size" = "$size" ] || die "size mismatch for $BIN_NAME (manifest $size, got $actual_size)"
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | awk '{print $1}'
  else die "no sha256 tool found (need sha256sum, shasum, or openssl)"
  fi
}
got="$(sha256_file "$tmp/$BIN_NAME")"
[ "$got" = "$sha256" ] \
  || die "SHA-256 checksum mismatch for $BIN_NAME (manifest $sha256, got $got)"

sums_entry="$(awk -v f="$BIN_NAME" '$2 == f || $2 == ("*" f) { print $1; exit }' "$tmp/SHA-256SUMS")"
[ -n "$sums_entry" ] || die "SHA-256SUMS has no entry for $BIN_NAME — refusing to install"
[ "$got" = "$sums_entry" ] \
  || die "SHA-256SUMS entry mismatch for $BIN_NAME ($sums_entry, got $got) — refusing to install"

if command -v minisign >/dev/null 2>&1; then
  if [ -n "$MINISIGN_PUBKEY" ]; then
    curl -fsSL "$url.sig" -o "$tmp/$BIN_NAME.sig" || die "failed to download signature: $url.sig"
    if [ -f "$MINISIGN_PUBKEY" ]; then
      minisign -Vm "$tmp/$BIN_NAME" -p "$MINISIGN_PUBKEY" -x "$tmp/$BIN_NAME.sig" >/dev/null 2>&1 \
        || die "minisign verification FAILED for $BIN_NAME"
    else
      minisign -Vm "$tmp/$BIN_NAME" -P "$MINISIGN_PUBKEY" -x "$tmp/$BIN_NAME.sig" >/dev/null 2>&1 \
        || die "minisign verification FAILED for $BIN_NAME"
    fi
    echo "install.sh: minisign signature OK"
  else
    echo "install.sh: note: minisign is installed but no public key was provided"
    echo "install.sh: note: (use --minisign-pubkey or RC_MINISIGN_PUBKEY) — signature check skipped"
  fi
else
  echo "install.sh: note: minisign not installed — artifact signature check skipped"
  echo "install.sh: note: integrity relies on TLS + manifest sha256 + SHA-256SUMS (TOFU over TLS)"
fi

# --- atomic install --------------------------------------------------------
if [ -n "$SUDO" ]; then
  sudo mkdir -p "$BIN_DIR"
  sudo chmod 755 "$tmp/$BIN_NAME"
  sudo mv -f "$tmp/$BIN_NAME" "$BIN_DIR/.$PROJECT.stage.$$"
  sudo mv -f "$BIN_DIR/.$PROJECT.stage.$$" "$BIN_DIR/$BIN_CMD"
else
  mkdir -p "$BIN_DIR"
  chmod 755 "$tmp/$BIN_NAME"
  mv -f "$tmp/$BIN_NAME" "$BIN_DIR/.$PROJECT.stage.$$"
  mv -f "$BIN_DIR/.$PROJECT.stage.$$" "$BIN_DIR/$BIN_CMD"
fi

echo "install.sh: installed $BIN_CMD $version ($TARGET) -> $BIN_DIR/$BIN_CMD"
if out="$("$BIN_DIR/$BIN_CMD" version 2>/dev/null)"; then
  v="$(printf '%s\n' "$out" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$v" ] && echo "install.sh: verified $PROJECT $v"
fi
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "install.sh: note: $BIN_DIR is not on your PATH — add it, e.g.:"
     echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
echo "install.sh: next: run '$BIN_CMD version'"
echo "install.sh: update later by re-running this one-liner; pin a lane with"
echo "install.sh:   --channel stable|beta|nightly  (alias: --lane)  |  --force to reinstall"
