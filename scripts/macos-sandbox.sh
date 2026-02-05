#!/usr/bin/env bash
# macos-sandbox.sh — macOS sandbox using sandbox-exec (Seatbelt)
#
# Called by claude-sandbox.sh. Expects these environment variables:
#   _CS_READ_ONLY_PATHS   — newline-delimited list
#   _CS_BLOCKED_PATHS     — newline-delimited list
#   _CS_WRITABLE_PATHS    — newline-delimited list
#   _CS_PROXY_PORT        — TCP port of the egress proxy
#   _CS_WORKSPACE         — workspace directory path
#   _CS_CLAUDE_BIN        — path to the claude binary
#   _CS_SESSION_ID        — unique session identifier
#   _CS_SESSION_DIR       — session directory for logs and context
#   CLAUDE_SANDBOX_SCRIPTS — path to the scripts directory

set -euo pipefail

# ── Read arrays from environment ──────────────────────────────
readarray -t READ_ONLY_PATHS <<< "$_CS_READ_ONLY_PATHS"
readarray -t BLOCKED_PATHS   <<< "$_CS_BLOCKED_PATHS"
readarray -t WRITABLE_PATHS  <<< "$_CS_WRITABLE_PATHS"

# ── Generate Seatbelt Profile ─────────────────────────────────
SB_PROFILE=$(mktemp /tmp/claude-sandbox-XXXXXX.sb)

# Use generate-seatbelt.sh if available, otherwise inline generation
GENERATE_SCRIPT="${CLAUDE_SANDBOX_SCRIPTS}/generate-seatbelt.sh"

if [[ -x "$GENERATE_SCRIPT" ]] || [[ -f "$GENERATE_SCRIPT" ]]; then
  bash "$GENERATE_SCRIPT" \
    --port "$_CS_PROXY_PORT" \
    --output "$SB_PROFILE" \
    --workspace "$_CS_WORKSPACE"
else
  # Fallback: inline generation
  echo "(version 1)"                                         > "$SB_PROFILE"
  echo ""                                                   >> "$SB_PROFILE"
  echo ";; Base: allow most operations, deny writes & net"  >> "$SB_PROFILE"
  echo "(allow default)"                                    >> "$SB_PROFILE"
  echo "(deny network*)"                                    >> "$SB_PROFILE"
  echo "(deny file-write*)"                                 >> "$SB_PROFILE"
  echo ""                                                   >> "$SB_PROFILE"
  echo ";; Network: only allow connection to our proxy"     >> "$SB_PROFILE"
  echo "(allow network-outbound (remote tcp \"localhost:${_CS_PROXY_PORT}\"))" >> "$SB_PROFILE"
  echo "(allow network* (local tcp))"                       >> "$SB_PROFILE"
  echo ""                                                   >> "$SB_PROFILE"

  # System paths that Node.js / Claude Code need to write to
  DARWIN_TEMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo '/tmp')"
  cat >> "$SB_PROFILE" <<SEOF
;; System write paths for Node.js / Claude
(allow file-write*
  (subpath "/private/tmp")
  (subpath "/private/var/folders")
  (subpath "${DARWIN_TEMP}")
  (subpath "${HOME}/.npm")
  (subpath "${HOME}/.claude")
  (subpath "${HOME}/.config/claude")
  (literal "${HOME}/.claude.json")
  (literal "${HOME}/.claude.json.tmp*")
)
SEOF

  # Writable paths from profile
  echo "" >> "$SB_PROFILE"
  echo ";; Profile: writable paths" >> "$SB_PROFILE"
  for path in "${WRITABLE_PATHS[@]}"; do
    [[ -z "$path" ]] && continue
    mkdir -p "$path" 2>/dev/null || true
    # Use pwd -P for physical path resolution (resolve symlinks)
    abs_path="$(cd "$path" 2>/dev/null && pwd -P || echo "$path")"
    echo "(allow file-write* (subpath \"$abs_path\"))" >> "$SB_PROFILE"
  done

  # Blocked paths (deny reads)
  echo "" >> "$SB_PROFILE"
  echo ";; Profile: blocked paths (deny reads)" >> "$SB_PROFILE"
  for path in "${BLOCKED_PATHS[@]}"; do
    [[ -z "$path" ]] && continue
    if [[ -e "$path" ]]; then
      # Use pwd -P for physical path resolution (resolve symlinks)
      abs_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")"
      echo "(deny file-read* (subpath \"$abs_path\"))" >> "$SB_PROFILE"
    fi
  done

  echo "" >> "$SB_PROFILE"
fi

# ── Environment isolation: build clean env array ─────────────
_ENV_ARGS=(
  HOME="$HOME"
  USER="${USER:-claude}"
  LANG="${LANG:-C.UTF-8}"
  TERM="${TERM:-xterm-256color}"
  TMPDIR="/tmp"
  PATH="$PATH"
  HTTP_PROXY="http://127.0.0.1:${_CS_PROXY_PORT}"
  HTTPS_PROXY="http://127.0.0.1:${_CS_PROXY_PORT}"
  ALL_PROXY="http://127.0.0.1:${_CS_PROXY_PORT}"
  NO_PROXY=""
  CLAUDE_SANDBOX_WORKSPACE="${_CS_WORKSPACE:-}"
)

# XDG dirs if set
[[ -n "${XDG_CONFIG_HOME:-}" ]] && _ENV_ARGS+=(XDG_CONFIG_HOME="$XDG_CONFIG_HOME")
[[ -n "${XDG_DATA_HOME:-}" ]] && _ENV_ARGS+=(XDG_DATA_HOME="$XDG_DATA_HOME")
[[ -n "${XDG_CACHE_HOME:-}" ]] && _ENV_ARGS+=(XDG_CACHE_HOME="$XDG_CACHE_HOME")

# Auth tokens if set
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && _ENV_ARGS+=(ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && _ENV_ARGS+=(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN")

# Profile-configured passthrough vars
readarray -t PASSTHROUGH_ENV <<< "${_CS_PASSTHROUGH_ENV:-}"
for var in "${PASSTHROUGH_ENV[@]}"; do
  [[ -n "$var" && -n "${!var:-}" ]] && _ENV_ARGS+=("$var=${!var}")
done

echo "  Launching Claude Code in Seatbelt sandbox..."
echo "  Seatbelt profile: $SB_PROFILE"
echo ""
exec env -i "${_ENV_ARGS[@]}" sandbox-exec -f "$SB_PROFILE" "$_CS_CLAUDE_BIN" "$@"
