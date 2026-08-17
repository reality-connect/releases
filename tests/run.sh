#!/bin/sh
# tests/run.sh — verification for the RC release tooling (install.sh).
#
#   tests/run.sh docker        (default) run the mocked install suite in a docker
#                              matrix: ubuntu:24.04, debian:12, alpine:3.21
#   tests/run.sh in-container  run the mocked install suite (inside a container;
#                              no network and no packages beyond busybox/coreutils)
#   tests/run.sh local         host checks: sh -n both scripts + live dry-run
#                              against the real new-seed beta pointer
#
# The in-container suite serves a fake channel pointer + SHA-256SUMS + binary via
# file:// (curl handles it; no server process needed) and asserts: target
# detection, channel selection, checksum refusal, SUMS refusal, unknown-flag
# refusal, bin-dir placement, idempotent updates, --force, and the minisign
# skip note.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
SECRETS="$ROOT/release-secrets.sh"
PASS=0
FAIL=0
FAILED=""

note() { echo "== $*"; }
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED="$FAILED $1"; echo "FAIL: $1"; }

# check_rc_out <name> <want_rc|nonzero> <want_substr|-> <-- ...command...>
check_rc_out() {
  name="$1"; want_rc="$2"; want_str="$3"; shift 3
  [ "$1" = "--" ] && shift
  out="$("$@" 2>&1)"; rc=$?
  rc_ok=0
  if [ "$want_rc" = "nonzero" ]; then [ "$rc" -ne 0 ] && rc_ok=1
  else [ "$rc" -eq "$want_rc" ] && rc_ok=1; fi
  str_ok=0
  if [ "$want_str" = "-" ]; then str_ok=1
  elif printf '%s' "$out" | grep -q -e "$want_str"; then str_ok=1; fi
  if [ "$rc_ok" = 1 ] && [ "$str_ok" = 1 ]; then
    ok "$name"
  else
    bad "$name"
    echo "  rc=$rc want=$want_rc (rc_ok=$rc_ok str_ok=$str_ok, wanted '$want_str')"
    printf '%s\n' "$out" | sed -n '1,12p' | sed 's/^/  | /'
  fi
}

detect_target() {
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Darwin) tos=darwin ;;
    Linux) tos=linux ;;
    *) echo "unsupported-os"; return 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) tarch=aarch64 ;;
    x86_64|amd64) tarch=x86_64 ;;
    *) echo "unsupported-arch"; return 1 ;;
  esac
  t="$tos-$tarch"
  if [ "$t" = "linux-x86_64" ]; then
    m=0
    ldd --version 2>/dev/null | grep -qi musl && m=1
    [ "$m" = 0 ] && command -v ldd >/dev/null 2>&1 && ldd /bin/sh 2>/dev/null | grep -qi 'ld-musl' && m=1
    if [ "$m" = 0 ]; then
      for l in /lib/ld-musl-* /usr/lib/ld-musl-*; do [ -e "$l" ] && m=1 && break; done
    fi
    if [ "$m" = 1 ]; then t="linux-x86_64-musl"; else t="linux-x86_64-gnu"; fi
  fi
  echo "$t"
}

# ---------------------------------------------------------------- local ----
local_checks() {
  note "syntax check (macOS sh)"
  check_rc_out "sh -n install.sh" 0 "-" -- sh -n "$INSTALLER"
  check_rc_out "sh -n release-secrets.sh" 0 "-" -- sh -n "$SECRETS"

  T="$(detect_target)" || { echo "cannot detect target"; exit 1; }
  note "live dry-run against reality-connect/releases (new-seed beta pointer)"
  check_rc_out "live pointer resolves to a plan" 0 "dry-run" -- sh "$INSTALLER" --project new-seed --channel beta --dry-run
  check_rc_out "live target is $T" 0 "target: $T" -- sh "$INSTALLER" --project new-seed --channel beta --dry-run
  check_rc_out "live plan names new-seed + beta" 0 "new-seed" -- sh "$INSTALLER" --project new-seed --channel beta --dry-run
  check_rc_out "live --lane alias works" 0 "dry-run" -- sh "$INSTALLER" --project new-seed --lane beta --dry-run

  note "one-liner invocation form (curl | sh -s -- --project ...)"
  out="$(sh -s -- --project new-seed --channel beta --dry-run < "$INSTALLER" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -e "dry-run"; then
    ok "stdin invocation parses its own flags"
  else
    bad "stdin invocation parses its own flags"
    printf '%s\n' "$out" | sed -n '1,8p' | sed 's/^/  | /'
  fi

  echo "----- live dry-run output -----"
  sh "$INSTALLER" --project new-seed --channel beta --dry-run
  echo "------------------------------"
}

# --------------------------------------------------------- in-container ----
container_suite() {
  T="$(detect_target)" || { echo "cannot detect target"; exit 1; }
  note "container: $(uname -s) $(uname -m) -> target $T"

  # base images ship without curl; bootstrap it (containers have network here)
  if ! command -v curl >/dev/null 2>&1; then
    note "installing curl"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null \
        || { echo "cannot install curl"; exit 1; }
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl >/dev/null || { echo "cannot install curl"; exit 1; }
    else
      echo "curl unavailable and no package manager found"; exit 1
    fi
  fi

  note "syntax"
  check_rc_out "sh -n install.sh" 0 "-" -- sh -n "$INSTALLER"
  check_rc_out "sh -n release-secrets.sh" 0 "-" -- sh -n "$SECRETS"

  # --- mock release tree (served via file://) ---
  MOCK="$(mktemp -d)"
  ZERO64="0000000000000000000000000000000000000000000000000000000000000000"
  mk_asset() { # $1 asset-dir  $2 version
    d="$MOCK/assets/$1"
    mkdir -p "$d"
    cat > "$d/cli-$T" <<EOF
#!/bin/sh
echo '{"defaultChannel":"beta","distributable":true,"target":"$T","version":"$2"}'
EOF
    chmod 755 "$d/cli-$T"
    sha256sum "$d/cli-$T" | awk '{print $1}' > "$d/.sha"
    (cd "$d" && sha256sum "cli-$T" > SHA-256SUMS)
  }
  mk_asset beta 2.0.0-beta.1
  mk_asset stable 1.0.0
  mk_asset sumsbad 3.0.0
  # tamper with the sumsbad SHA-256SUMS (manifest sha stays correct)
  printf '%s  cli-%s\n' "$ZERO64" "$T" > "$MOCK/assets/sumsbad/SHA-256SUMS"

  mk_pointer() { # $1 channel  $2 asset-dir  $3 sha  $4 version
    mkdir -p "$MOCK/seed-channel-$1"
    cat > "$MOCK/seed-channel-$1/$1.json" <<EOF
{
  "schemaVersion": 2,
  "channel": "$1",
  "version": "$4",
  "pub_date": "2026-08-17T00:00:00.000Z",
  "cli": {
    "$T": {
      "url": "file://$MOCK/assets/$2/cli-$T",
      "sha256": "$3",
      "size": $(wc -c < "$MOCK/assets/$2/cli-$T")
    }
  }
}
EOF
  }
  mk_pointer beta   beta   "$(cat "$MOCK/assets/beta/.sha")"   2.0.0-beta.1
  mk_pointer stable stable "$(cat "$MOCK/assets/stable/.sha")" 1.0.0
  mk_pointer bad    beta   "$ZERO64"                           9.9.9
  mk_pointer sumsbad sumsbad "$(cat "$MOCK/assets/sumsbad/.sha")" 3.0.0

  export RC_RELEASES_BASE_URL="file://$MOCK"
  BIN=/opt/testbin
  BIN2=/opt/testbin2
  BIN3=/opt/testbin3
  BIN4=/opt/testbin4
  rm -rf "$BIN" "$BIN2" "$BIN3" "$BIN4"

  note "target detection + dry-run (channel beta)"
  check_rc_out "dry-run resolves beta version" 0 "2.0.0-beta.1" -- \
    sh "$INSTALLER" --project seed --channel beta --bin-dir "$BIN" --dry-run
  check_rc_out "dry-run target is $T" 0 "target: $T" -- \
    sh "$INSTALLER" --project seed --channel beta --bin-dir "$BIN" --dry-run
  check_rc_out "dry-run binary URL basename is cli-$T" 0 "cli-$T" -- \
    sh "$INSTALLER" --project seed --channel beta --bin-dir "$BIN" --dry-run
  check_rc_out "dry-run installs nothing" 0 "-" -- test ! -e "$BIN/seed"

  note "install (beta)"
  check_rc_out "install beta succeeds" 0 "installed" -- \
    sh "$INSTALLER" --project seed --channel beta --bin-dir "$BIN"
  check_rc_out "binary placed in --bin-dir" 0 "-" -- test -x "$BIN/seed"
  check_rc_out "installed binary reports beta version" 0 "2.0.0-beta.1" -- "$BIN/seed" version
  check_rc_out "minisign skip note printed" 0 "minisign" -- \
    sh "$INSTALLER" --project seed --channel beta --bin-dir "$BIN" --force

  note "idempotent updates"
  INODE1="$(stat -c %i "$BIN/seed")"
  check_rc_out "same version skips (up to date)" 0 "up to date" -- \
    sh "$INSTALLER" --project seed --channel beta --bin-dir "$BIN"
  INODE2="$(stat -c %i "$BIN/seed")"
  [ "$INODE1" = "$INODE2" ] && ok "skip did not rewrite the binary" \
    || bad "skip did not rewrite the binary"
  check_rc_out "--force reinstalls" 0 "installed" -- \
    sh "$INSTALLER" --project seed --channel beta --bin-dir "$BIN" --force
  INODE3="$(stat -c %i "$BIN/seed")"
  [ "$INODE3" != "$INODE2" ] && ok "--force replaced the binary" \
    || bad "--force replaced the binary"

  note "channel selection"
  check_rc_out "install stable channel" 0 "installed" -- \
    sh "$INSTALLER" --project seed --channel stable --bin-dir "$BIN2"
  check_rc_out "stable pointer manifest was read" 0 "stable.json" -- \
    sh "$INSTALLER" --project seed --channel stable --bin-dir "$BIN2" --dry-run
  check_rc_out "stable binary reports 1.0.0" 0 "1.0.0" -- "$BIN2/seed" version
  check_rc_out "--lane alias selects channel" 0 "installed" -- \
    sh "$INSTALLER" --project seed --lane stable --bin-dir "$BIN3"
  check_rc_out "--lane installed 1.0.0" 0 "1.0.0" -- "$BIN3/seed" version

  note "refusals"
  check_rc_out "checksum mismatch refused" nonzero "checksum" -- \
    sh "$INSTALLER" --project seed --channel bad --bin-dir "$BIN4"
  check_rc_out "tampered SHA-256SUMS refused" nonzero "SHA-256SUMS" -- \
    sh "$INSTALLER" --project seed --channel sumsbad --bin-dir "$BIN4"
  check_rc_out "unpublished channel refused" nonzero "failed to fetch" -- \
    sh "$INSTALLER" --project seed --channel nightly --bin-dir "$BIN4" --dry-run
  check_rc_out "unknown flag refused" nonzero "unknown option" -- \
    sh "$INSTALLER" --project seed --bogus
  check_rc_out "missing --project refused" nonzero "--project is required" -- \
    sh "$INSTALLER"
  check_rc_out "invalid channel refused" nonzero "invalid --channel" -- \
    sh "$INSTALLER" --project seed --channel 'stable/beta' --dry-run

  note "default bin-dir resolution"
  rm -rf "$HOME/.local/bin"
  mkdir -p "$HOME/.local/bin"
  if [ "$T" = "linux-x86_64-musl" ]; then
    DEFDIR=/usr/local/bin   # alpine/musl always defaults to /usr/local/bin
  else
    DEFDIR="$HOME/.local/bin"
  fi
  check_rc_out "default bin-dir resolves to $DEFDIR" 0 "installed" -- \
    sh "$INSTALLER" --project seed --channel beta
  check_rc_out "binary landed in $DEFDIR" 0 "-" -- test -x "$DEFDIR/seed"

  rm -rf "$MOCK"
}

# --------------------------------------------------------------- docker ----
docker_matrix() {
  for img in ubuntu:24.04 debian:12 alpine:3.21; do
    name="$(printf '%s' "$img" | tr '/:' '__')"
    log="$ROOT/tests/results/$name.log"
    mkdir -p "$ROOT/tests/results"
    echo "===== $img ====="
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "pulling $img ..."
      if ! docker pull "$img" >/dev/null 2>&1; then
        if [ "$img" = "alpine:3.21" ]; then
          echo "alpine:3.21 pull failed — retrying via mirror.gcr.io"
          docker pull mirror.gcr.io/library/alpine:3.21 >/dev/null 2>&1 || { echo "FAIL: $img (pull)"; continue; }
          img="mirror.gcr.io/library/alpine:3.21"
          name="alpine-3.21-mirror"
          log="$ROOT/tests/results/$name.log"
        else
          echo "FAIL: $img (pull)"
          continue
        fi
      fi
    fi
    if docker run --rm --platform linux/amd64 -v "$ROOT":/src -w /src "$img" sh tests/run.sh in-container >"$log" 2>&1; then
      tail -1 "$log"
      echo "PASS: $img  (log: tests/results/$name.log)"
    else
      tail -25 "$log"
      echo "FAIL: $img  (log: tests/results/$name.log)"
    fi
  done
}

# ------------------------------------------------------------------ main ---
mode="${1:-docker}"
case "$mode" in
  docker) docker_matrix ;;
  in-container) container_suite ;;
  local) local_checks ;;
  *) echo "usage: tests/run.sh <docker|in-container|local>" >&2; exit 64 ;;
esac

echo
echo "checks: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "failed:$FAILED"
  exit 1
fi
exit 0
