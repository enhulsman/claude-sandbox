#!/usr/bin/env bash
# claude-sandbox.sh — Platform-adaptive launcher for sandboxed Claude Code
#
# This is the main entry point. It:
#   1. Parses arguments and loads the requested profile from config.toml
#   2. Starts the egress-filtering proxy
#   3. Dispatches to linux-sandbox.sh or macos-sandbox.sh
#
# Environment variables set by the Nix flake wrapper:
#   CLAUDE_SANDBOX_SCRIPTS   — path to the scripts/ directory
#   CLAUDE_SANDBOX_PROXY     — path to the egress-proxy.py binary
#   CLAUDE_SANDBOX_CONFIG    — path to config.toml
#   CLAUDE_SANDBOX_IS_LINUX  — "1" or "0"
#   CLAUDE_SANDBOX_IS_DARWIN — "1" or "0"

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────
PROFILE="${CLAUDE_SANDBOX_PROFILE:-dev}"
WORKSPACE="${CLAUDE_SANDBOX_WORKSPACE:-$HOME/claude-workspace}"
CONFIG_FILE="${CLAUDE_SANDBOX_CONFIG:-}"
SCRIPTS_DIR="${CLAUDE_SANDBOX_SCRIPTS:-$(cd "$(dirname "$0")" && pwd)}"
PROXY_BIN="${CLAUDE_SANDBOX_PROXY:-claude-egress-proxy}"

# ── Load Defaults File ──────────────────────────────────────
# Priority: CLI flags > env vars > defaults file > hardcoded defaults
# Recognized keys: CLAUDE_SANDBOX_PROFILE, CLAUDE_SANDBOX_WORKSPACE,
#                  CLAUDE_SANDBOX_YOLO
_CS_DEFAULTS_FILE="${CLAUDE_SANDBOX_DEFAULTS:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandbox/defaults}"
_CS_DEFAULT_YOLO=""

if [[ -f "$_CS_DEFAULTS_FILE" ]]; then
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Skip comments and blank lines
    _line="${_line%%#*}"
    [[ -z "${_line// /}" ]] && continue
    _key="${_line%%=*}"
    _val="${_line#*=}"
    # Trim whitespace
    _key="${_key#"${_key%%[![:space:]]*}"}"
    _key="${_key%"${_key##*[![:space:]]}"}"
    _val="${_val#"${_val%%[![:space:]]*}"}"
    _val="${_val%"${_val##*[![:space:]]}"}"
    # Strip surrounding quotes
    _val="${_val#\"}" ; _val="${_val%\"}"
    _val="${_val#\'}" ; _val="${_val%\'}"
    case "$_key" in
      CLAUDE_SANDBOX_PROFILE)
        # Only apply if not already set via env var
        PROFILE="${CLAUDE_SANDBOX_PROFILE:-$_val}" ;;
      CLAUDE_SANDBOX_WORKSPACE)
        WORKSPACE="${CLAUDE_SANDBOX_WORKSPACE:-$_val}" ;;
      CLAUDE_SANDBOX_YOLO)
        _CS_DEFAULT_YOLO="$_val" ;;
    esac
  done < "$_CS_DEFAULTS_FILE"
fi

PROXY_PORT=""
PROXY_PID=""
SOCAT_PID=""
SOCKET_DIR=""

# ── Usage ─────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: claude-sandbox [OPTIONS] [-- CLAUDE_ARGS...]
       claude-sandbox --exec COMMAND [ARGS...]

Options:
  --profile PROFILE   Security profile (default: dev)
  --workspace DIR     Writable workspace directory (default: ~/claude-workspace)
  --config FILE       Path to config.toml
  --exec CMD [ARGS]   Run CMD instead of Claude Code (for testing/verify)
  --shell             Shortcut for --exec bash (interactive shell in sandbox)
  --yolo              Pass --dangerously-skip-permissions to Claude Code
                      (safe when using the external sandbox as the boundary)
  --dry-run           Show what would be done without executing
  -h, --help          Show this help

Profiles:
  nixos-admin    Read /etc/nixos, /var/log, /nix — for system diagnosis
  dev            Read project dir + system libs — for software development
  strict         Minimal access — for untrusted repos
  macos-admin    Read /Library, /opt/homebrew — for macOS system diagnosis

Examples:
  claude-sandbox --profile dev -- -p "review this codebase"
  claude-sandbox --profile dev --yolo                       # autonomous mode
  claude-sandbox --profile dev --exec bash                  # interactive shell
  claude-sandbox --profile dev --shell                      # same as above
  claude-sandbox --profile dev --exec bash verify.sh        # run a script
  claude-sandbox --profile strict -- -p "audit this repo"
EOF
  exit 0
}

# ── Parse Arguments ───────────────────────────────────────────
CLAUDE_ARGS=()
EXEC_CMD=()
DRY_RUN=0
YOLO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)   PROFILE="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --config)    CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --yolo)      YOLO=1; shift ;;
    --shell)     EXEC_CMD=("bash"); break ;;
    --exec)      shift; EXEC_CMD=("$@"); break ;;
    -h|--help)   usage ;;
    --)          shift; CLAUDE_ARGS=("$@"); break ;;
    *)           CLAUDE_ARGS+=("$1"); shift ;;
  esac
done

# Apply default YOLO if not set via CLI flag
if [[ "$YOLO" == "0" && "$_CS_DEFAULT_YOLO" == "1" ]]; then
  YOLO=1
fi

# ── Setup Workspace ───────────────────────────────────────────
mkdir -p "$WORKSPACE"
AUDIT_LOG="$WORKSPACE/.proxy-audit.log"

# ── TOML Profile Parser ──────────────────────────────────────
# Minimal parser: extracts string arrays from [profile.NAME.section] key = [...]
# Handles multi-line arrays with one quoted string per line.

parse_profile_array() {
  local file="$1" profile="$2" key="$3"
  # key is dotted: "filesystem.read_only" → section=filesystem, field=read_only
  local section="${key%%.*}"
  local field="${key#*.}"

  awk -v profile="$profile" -v section="$section" -v field="$field" '
    BEGIN { in_profile=0; in_section=0; in_array=0 }

    # Match [profile.NAME]
    /^\[profile\.[a-zA-Z0-9_-]+\]$/ {
      gsub(/[\[\]]/, "")
      split($0, p, ".")
      in_profile = (p[2] == profile)
      in_section = 0
      in_array = 0
      next
    }

    # Match [profile.NAME.SECTION]
    /^\[profile\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_]+\]$/ {
      gsub(/[\[\]]/, "")
      split($0, p, ".")
      if (p[2] == profile && p[3] == section) {
        in_profile = 1
        in_section = 1
      } else {
        in_section = 0
      }
      in_array = 0
      next
    }

    # Any other section header ends our context
    /^\[/ {
      in_section = 0
      in_array = 0
      next
    }

    # Match the field = [ opening
    in_profile && in_section && !in_array {
      pat = "^" field " *= *\\["
      if ($0 ~ pat) {
        in_array = 1
        # Check for single-line array: field = ["val1", "val2"]
        if ($0 ~ /\]/) {
          # Single line — extract all quoted strings
          line = $0
          while (match(line, /"([^"]*)"/, m)) {
            val = m[1]
            gsub(/^~/, ENVIRON["HOME"], val)
            print val
            line = substr(line, RSTART + RLENGTH)
          }
          in_array = 0
        }
        next
      }
    }

    # Inside a multi-line array
    in_array && /\]/ { in_array = 0; next }
    in_array && /^[[:space:]]*"/ {
      gsub(/^[[:space:]]*"|"[[:space:]]*,?[[:space:]]*(#.*)?$/, "")
      gsub(/^~/, ENVIRON["HOME"])
      if (length($0) > 0) print
    }
  ' "$file"
}

# ── Load Profile ──────────────────────────────────────────────
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_FILE:-'(not set)'}" >&2
  echo "  Set CLAUDE_SANDBOX_CONFIG or use --config /path/to/config.toml" >&2
  exit 1
fi

declare -a READ_ONLY_PATHS=()
declare -a BLOCKED_PATHS=()
declare -a WRITABLE_PATHS=()
declare -a ALLOWED_DOMAINS=()

while IFS= read -r line; do [[ -n "$line" ]] && READ_ONLY_PATHS+=("$line"); done < \
  <(parse_profile_array "$CONFIG_FILE" "$PROFILE" "filesystem.read_only")
while IFS= read -r line; do [[ -n "$line" ]] && BLOCKED_PATHS+=("$line"); done < \
  <(parse_profile_array "$CONFIG_FILE" "$PROFILE" "filesystem.blocked")
while IFS= read -r line; do [[ -n "$line" ]] && WRITABLE_PATHS+=("$line"); done < \
  <(parse_profile_array "$CONFIG_FILE" "$PROFILE" "filesystem.writable")
while IFS= read -r line; do [[ -n "$line" ]] && ALLOWED_DOMAINS+=("$line"); done < \
  <(parse_profile_array "$CONFIG_FILE" "$PROFILE" "network.allowed_domains")

# Workspace is always writable
WRITABLE_PATHS+=("$WORKSPACE")

if [[ ${#ALLOWED_DOMAINS[@]} -eq 0 ]]; then
  echo "WARNING: No allowed domains in profile '$PROFILE' — Claude API calls will fail" >&2
fi

# Export arrays for sub-scripts (newline-delimited)
export _CS_READ_ONLY_PATHS
_CS_READ_ONLY_PATHS="$(printf '%s\n' "${READ_ONLY_PATHS[@]}")"
export _CS_BLOCKED_PATHS
_CS_BLOCKED_PATHS="$(printf '%s\n' "${BLOCKED_PATHS[@]}")"
export _CS_WRITABLE_PATHS
_CS_WRITABLE_PATHS="$(printf '%s\n' "${WRITABLE_PATHS[@]}")"
export _CS_ALLOWED_DOMAINS
_CS_ALLOWED_DOMAINS="$(printf '%s\n' "${ALLOWED_DOMAINS[@]}")"
export _CS_WORKSPACE="$WORKSPACE"
export _CS_AUDIT_LOG="$AUDIT_LOG"

# ── Generate Sandbox Context for Claude Code ─────────────────
# Creates a system prompt addendum so Claude Code understands it's running
# in a sandbox and can handle restrictions gracefully instead of getting
# confused by missing files or blocked network requests.
# Uses --append-system-prompt-file to inject without touching user files.
SANDBOX_CONTEXT_FILE="$WORKSPACE/.sandbox-context.md"
if [[ ${#EXEC_CMD[@]} -eq 0 ]]; then
  cat > "$SANDBOX_CONTEXT_FILE" <<CONTEXT_EOF
# Sandbox Environment

You are running inside claude-sandbox (profile: $PROFILE), an external
security sandbox that restricts your filesystem and network access.
This is intentional and protects the user's system. Work within these
constraints gracefully — do not try to work around them.

## Filesystem

Blocked paths (will return "No such file" or "Permission denied"):
$(for p in "${BLOCKED_PATHS[@]}"; do [[ -n "$p" ]] && echo "- $p"; done)

These files are intentionally hidden from you. Do not suggest the user
check if they exist — they do, but the sandbox blocks access.
If a task requires a blocked file (e.g. SSH config for git operations),
explain what you need and ask the user to perform that step outside
the sandbox.

Read-only paths (you can read but not write):
$(for p in "${READ_ONLY_PATHS[@]}"; do [[ -n "$p" ]] && echo "- $p"; done)

Writable paths:
$(for p in "${WRITABLE_PATHS[@]}"; do [[ -n "$p" ]] && echo "- $p"; done)
- $WORKSPACE (sandbox workspace — always writable)

Write all output files to the workspace: $WORKSPACE

## Network

All network traffic goes through a filtering proxy. Only these domains
are reachable:
$(for d in "${ALLOWED_DOMAINS[@]}"; do echo "- $d"; done)

Any request to other domains will be blocked. Do not attempt to curl,
wget, or fetch from unlisted domains — it will fail silently or return
a connection error. If you need a resource from a blocked domain,
tell the user which URL you need and ask them to provide the content.

## Handling Restrictions

When you encounter a "Permission denied", "No such file", or
"Connection refused" error:
1. Check if the path/domain is in the blocked/unlisted lists above
2. If yes: explain to the user that the sandbox blocks this access
   and suggest an alternative approach
3. Do NOT retry the same command or attempt workarounds
CONTEXT_EOF

  # Inject the context file as a system prompt addendum
  CLAUDE_ARGS=("--append-system-prompt-file" "$SANDBOX_CONTEXT_FILE" "${CLAUDE_ARGS[@]}")
fi

# ── Inject --dangerously-skip-permissions if --yolo ──────────
if [[ "$YOLO" == "1" && ${#EXEC_CMD[@]} -eq 0 ]]; then
  CLAUDE_ARGS=("--dangerously-skip-permissions" "${CLAUDE_ARGS[@]}")
fi

# ── Locate Claude Binary (skip in --exec mode) ──────────────
if [[ ${#EXEC_CMD[@]} -gt 0 ]]; then
  # --exec mode: use the command as-is (don't resolve symlinks).
  # Resolving would break multicall binaries like Nix coreutils
  # where argv[0] determines the subcommand (cat, ls, etc.)
  EXEC_BIN="$(command -v "${EXEC_CMD[0]}" 2>/dev/null || echo "${EXEC_CMD[0]}")"
  export _CS_CLAUDE_BIN="$EXEC_BIN"
  export _CS_CLAUDE_BIN_REAL="$EXEC_BIN"
  export _CS_EXEC_MODE=1
  CLAUDE_ARGS=("${EXEC_CMD[@]:1}")
else
  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  if [[ -z "$CLAUDE_BIN" ]]; then
    echo "ERROR: 'claude' not found in PATH." >&2
    echo "  This should not happen - Claude Code is bundled with the sandbox." >&2
    echo "  Please report this as a bug: https://github.com/enhulsman/claude-sandbox/issues" >&2
    exit 1
  fi
  CLAUDE_BIN_REAL="$(readlink -f "$CLAUDE_BIN")"
  export _CS_CLAUDE_BIN="$CLAUDE_BIN"
  export _CS_CLAUDE_BIN_REAL="$CLAUDE_BIN_REAL"
fi

# ── Start Egress Proxy ────────────────────────────────────────
start_proxy() {
  # Find a free port
  PROXY_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')

  local domain_args=()
  for domain in "${ALLOWED_DOMAINS[@]}"; do
    domain_args+=(--allow "$domain")
  done

  # Redirect proxy output to log file to avoid polluting Claude Code's TUI.
  # Startup messages go to a separate log; audit entries go to AUDIT_LOG.
  PROXY_LOG="$WORKSPACE/.proxy.log"

  "$PROXY_BIN" \
    --port "$PROXY_PORT" \
    --audit-log "$AUDIT_LOG" \
    "${domain_args[@]}" >>"$PROXY_LOG" 2>&1 &
  PROXY_PID=$!

  # Wait for proxy to be ready (up to 5 seconds)
  # Uses curl instead of python3 — much faster to spawn, especially on ARM.
  local ready=0
  for _ in $(seq 1 50); do
    if curl -so /dev/null --connect-timeout 0.2 "http://127.0.0.1:${PROXY_PORT}/" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.1
  done

  if [[ "$ready" -ne 1 ]]; then
    # One final check with visible errors for debugging
    echo "ERROR: Egress proxy failed to start on port $PROXY_PORT" >&2
    echo "  Checking if proxy process ($PROXY_PID) is alive..." >&2
    if kill -0 "$PROXY_PID" 2>/dev/null; then
      echo "  Process IS alive but not accepting connections." >&2
      echo "  Try manually: curl -v http://127.0.0.1:${PROXY_PORT}/" >&2
    else
      echo "  Process has EXITED. Check stderr above for errors." >&2
    fi
    exit 1
  fi
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
  local exit_code=$?

  [[ -n "${PROXY_PID:-}" ]]  && kill "$PROXY_PID" 2>/dev/null || true
  [[ -n "${SOCAT_PID:-}" ]]  && kill "$SOCAT_PID" 2>/dev/null || true
  [[ -n "${SOCKET_DIR:-}" ]] && rm -rf "$SOCKET_DIR" 2>/dev/null || true
  wait 2>/dev/null || true

  # Session summary
  if [[ -f "$AUDIT_LOG" ]]; then
    local blocked_count allowed_count
    blocked_count=$(grep -c "BLOCKED" "$AUDIT_LOG" 2>/dev/null || echo "0")
    allowed_count=$(grep -c "ALLOWED" "$AUDIT_LOG" 2>/dev/null || echo "0")
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Session Summary"
    echo "  Allowed requests: $allowed_count"
    echo "  Blocked requests: $blocked_count"
    if [[ "$blocked_count" -gt 0 ]]; then
      echo ""
      echo "  ⚠  BLOCKED REQUESTS (review these):"
      grep "BLOCKED" "$AUDIT_LOG" | tail -10 | sed 's/^/     /'
    fi
    echo "  Audit log: $AUDIT_LOG"
    echo "═══════════════════════════════════════════"
  fi

  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ── Banner ────────────────────────────────────────────────────
PLATFORM_LABEL="unknown"
if [[ "${CLAUDE_SANDBOX_IS_LINUX:-0}" == "1" ]]; then
  PLATFORM_LABEL="bubblewrap (Linux)"
elif [[ "${CLAUDE_SANDBOX_IS_DARWIN:-0}" == "1" ]]; then
  PLATFORM_LABEL="sandbox-exec / Seatbelt (macOS)"
fi

echo ""
echo "┌──────────────────────────────────────────────────┐"
echo "│  Claude Sandbox                                  │"
echo "│  Profile:   $PROFILE"
echo "│  Workspace: $WORKSPACE"
echo "│  Sandbox:   $PLATFORM_LABEL"
if [[ "$YOLO" == "1" ]]; then
echo "│  Permissions: skip (--yolo)"
fi
echo "└──────────────────────────────────────────────────┘"

# ── Dry Run ───────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  echo ""
  echo "[DRY RUN] Would launch Claude Code with:"
  echo "  Read-only paths:"
  for p in "${READ_ONLY_PATHS[@]}"; do echo "    $p"; done
  echo "  Blocked paths:"
  for p in "${BLOCKED_PATHS[@]}"; do echo "    $p"; done
  echo "  Writable paths:"
  for p in "${WRITABLE_PATHS[@]}"; do echo "    $p"; done
  echo "  Allowed domains:"
  for d in "${ALLOWED_DOMAINS[@]}"; do echo "    $d"; done
  exit 0
fi

# ── Start Proxy and Dispatch ──────────────────────────────────
start_proxy
export _CS_PROXY_PORT="$PROXY_PORT"

echo "  Proxy: port $PROXY_PORT (PID $PROXY_PID)"
echo ""

if [[ "${CLAUDE_SANDBOX_IS_LINUX:-0}" == "1" ]]; then
  exec bash "$SCRIPTS_DIR/linux-sandbox.sh" "${CLAUDE_ARGS[@]}"
elif [[ "${CLAUDE_SANDBOX_IS_DARWIN:-0}" == "1" ]]; then
  exec bash "$SCRIPTS_DIR/macos-sandbox.sh" "${CLAUDE_ARGS[@]}"
else
  echo "ERROR: Unsupported platform. Set CLAUDE_SANDBOX_IS_LINUX=1 or CLAUDE_SANDBOX_IS_DARWIN=1." >&2
  exit 1
fi
