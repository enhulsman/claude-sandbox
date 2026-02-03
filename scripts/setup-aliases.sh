#!/usr/bin/env bash
# setup-aliases.sh — Generate or install shell aliases for Claude Sandbox
#
# Usage:
#   bash scripts/setup-aliases.sh                     # preview aliases (stdout)
#   bash scripts/setup-aliases.sh --install           # write to shell rc file
#   bash scripts/setup-aliases.sh --github --install  # use GitHub URL
#   bash scripts/setup-aliases.sh /path/to/flake      # explicit flake path

set -euo pipefail

SENTINEL_BEGIN="# ── Claude Sandbox Aliases ──"
SENTINEL_END="# ── End Claude Sandbox Aliases ──"

INSTALL=0
USE_GITHUB=0
FLAKE_PATH=""

# ── Parse Arguments ───────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)  INSTALL=1; shift ;;
    --github)   USE_GITHUB=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: setup-aliases.sh [OPTIONS] [FLAKE_PATH]

Generate shell aliases for Claude Sandbox.

Options:
  --install     Write aliases to ~/.bashrc or ~/.zshrc (idempotent)
  --github      Use github:enhulsman/claude-sandbox instead of local path
  -h, --help    Show this help

Arguments:
  FLAKE_PATH    Explicit path to the flake (auto-detected if omitted)

Examples:
  bash scripts/setup-aliases.sh                     # preview
  bash scripts/setup-aliases.sh --install           # write to shell rc
  bash scripts/setup-aliases.sh --github --install  # use GitHub URL
  bash scripts/setup-aliases.sh ~/my-sandbox        # explicit path
EOF
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      FLAKE_PATH="$1"; shift ;;
  esac
done

# ── Resolve Flake Path ────────────────────────────────────────
if [[ "$USE_GITHUB" == "1" ]]; then
  FLAKE_REF="github:enhulsman/claude-sandbox"
elif [[ -n "$FLAKE_PATH" ]]; then
  FLAKE_REF="$FLAKE_PATH"
else
  # Walk up from script directory to find flake.nix
  dir="$(cd "$(dirname "$0")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/flake.nix" ]]; then
      FLAKE_REF="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done
  if [[ -z "${FLAKE_REF:-}" ]]; then
    echo "ERROR: Could not find flake.nix. Specify a path or use --github." >&2
    exit 1
  fi
fi

# ── Generate Alias Block ─────────────────────────────────────
generate_aliases() {
  cat <<EOF
$SENTINEL_BEGIN
alias claude='nix run ${FLAKE_REF}#claude --'
alias cs='nix run ${FLAKE_REF}#cs --'
alias csd='nix run ${FLAKE_REF}#csd --'
alias css='nix run ${FLAKE_REF}#css --'
alias claude-sandbox='nix run ${FLAKE_REF} --'
$SENTINEL_END
EOF
}

# ── Determine RC File ─────────────────────────────────────────
detect_rc_file() {
  case "${SHELL:-/bin/bash}" in
    */zsh)  echo "$HOME/.zshrc" ;;
    *)      echo "$HOME/.bashrc" ;;
  esac
}

# ── Install or Print ──────────────────────────────────────────
if [[ "$INSTALL" == "1" ]]; then
  RC_FILE="$(detect_rc_file)"
  ALIAS_BLOCK="$(generate_aliases)"

  if [[ ! -f "$RC_FILE" ]]; then
    touch "$RC_FILE"
  fi

  if grep -qF "$SENTINEL_BEGIN" "$RC_FILE"; then
    # Replace existing block in-place
    # Create a temp file with the block replaced
    tmpfile="$(mktemp)"
    awk -v begin="$SENTINEL_BEGIN" -v end="$SENTINEL_END" -v block="$ALIAS_BLOCK" '
      $0 == begin { skip=1; print block; next }
      $0 == end   { skip=0; next }
      !skip       { print }
    ' "$RC_FILE" > "$tmpfile"
    mv "$tmpfile" "$RC_FILE"
    echo "Updated aliases in $RC_FILE"
  else
    # Append
    printf '\n%s\n' "$ALIAS_BLOCK" >> "$RC_FILE"
    echo "Added aliases to $RC_FILE"
  fi
  echo "Restart your shell or run: source $RC_FILE"
else
  generate_aliases
fi
