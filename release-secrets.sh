#!/usr/bin/env bash
# release-secrets.sh — project-generic release-secret custody helper (non-interactive).
# Generalized from the original new-seed rc-release-secrets.sh: nothing is
# hardcoded to a project — the GitHub repo is always explicit via --repo.
#
# Custody model: Apple Passwords is the sole recovery copy (secret text +
# passphrase notes); GitHub Actions secrets are the only online copies. This
# repo holds NO secrets — only this helper.
#
#   release-secrets.sh --repo owner/name vault <label> <file>
#       Stage ONE custody item on the clipboard: paste the file's content into
#       Apple Passwords under <label> (e.g. 'secure NOTE "RC release artifact key"').
#       Nothing waits on Enter; run once per item. macOS (pbcopy) required.
#
#   release-secrets.sh --repo owner/name upload <SECRET_NAME>
#       Forward ONE value to a GitHub Actions secret (hidden input piped straight
#       to gh; never on disk, never echoed). Empty input is refused.
#
#   release-secrets.sh --repo owner/name upload-signing <artifact-key> <artifact-pass> \
#                                                      <manifest-key> <manifest-pass>
#       Set the four release-signing secrets directly from explicit local files
#       (no input needed; agent-runnable). All four files must exist and be
#       non-empty; any gh failure aborts with nothing silently half-set.
#
# After everything is in GitHub + Passwords, destroy the local plaintext copies.
set -eu

REPO=""

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

die() { echo "error: $*" >&2; exit 1; }

# --- parse flags (--repo must come before the subcommand) -----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"; shift 2
      ;;
    -h|--help) usage ;;
    --*) echo "release-secrets.sh: unknown option: $1" >&2; usage ;;
    *) break ;;   # subcommand and its arguments keep their quoting
  esac
done
sub="${1:-}"
[ -n "$sub" ] || usage
shift

require_repo() {
  [ -n "$REPO" ] || die "--repo owner/name is required for '$sub'"
  case "$REPO" in
    */*) [ "$(printf '%s' "$REPO" | tr -cd '/')" = "/" ] || die "invalid --repo (want owner/name): $REPO" ;;
    *) die "invalid --repo (want owner/name): $REPO" ;;
  esac
}

require_gh() {
  command -v gh >/dev/null 2>&1 || die "gh not found — install the GitHub CLI first"
}

case "$sub" in
  vault)
    label="${1:-}"
    file="${2:-}"
    [ "$#" -eq 2 ] || usage
    [ -n "$label" ] || { echo "usage: release-secrets.sh --repo owner/name vault <label> <file>" >&2; exit 64; }
    command -v pbcopy >/dev/null 2>&1 || die "pbcopy not found — 'vault' is macOS-only (Apple Passwords)"
    [ -f "$file" ] || die "file not found: $file"
    [ -s "$file" ] || die "file is empty — refusing to stage: $file"
    pbcopy < "$file"
    echo "Clipboard holds the content of: $file"
    echo "Paste it into Apple Passwords as: $label"
    echo "Clear the clipboard afterwards with: printf '' | pbcopy"
    ;;

  upload)
    name="${1:-}"
    [ "$#" -eq 1 ] || usage
    require_repo
    require_gh
    case "$name" in
      [A-Za-z_][A-Za-z0-9_]*) ;;
      *) echo "usage: release-secrets.sh --repo owner/name upload <SECRET_NAME>" >&2; exit 64 ;;
    esac
    printf 'lock %s\npaste value, then Enter (input hidden): ' "$name"
    if [ -t 0 ]; then
      read -rs value || { echo 'aborted - nothing set'; exit 1; }
    else
      IFS= read -r value || true
    fi
    [ -n "${value:-}" ] || { echo 'empty input - not set'; exit 1; }
    printf '%s' "$value" | gh secret set "$name" --repo "$REPO" \
      || { echo "gh FAILED - $name NOT set"; exit 1; }
    unset value
    echo ' -> set'
    ;;

  upload-signing)
    artifact_key="${1:-}"
    artifact_pass="${2:-}"
    manifest_key="${3:-}"
    manifest_pass="${4:-}"
    [ "$#" -eq 4 ] || usage
    require_repo
    require_gh
    for f in "$artifact_key" "$artifact_pass" "$manifest_key" "$manifest_pass"; do
      [ -f "$f" ] || die "file not found: $f"
      [ -s "$f" ] || die "file is empty — refusing to set secrets from: $f"
    done
    for pair in "TAURI_SIGNING_PRIVATE_KEY $artifact_key" \
                "TAURI_SIGNING_PRIVATE_KEY_PASSWORD $artifact_pass" \
                "RELEASE_MANIFEST_SIGNING_KEY $manifest_key" \
                "RELEASE_MANIFEST_SIGNING_KEY_PASSWORD $manifest_pass"; do
      set -- $pair
      gh secret set "$1" --repo "$REPO" < "$2" \
        || { echo "gh FAILED - $1 NOT set"; exit 1; }
    done
    echo "four signing secrets set on $REPO"
    ;;

  *)
    usage ;;
esac
