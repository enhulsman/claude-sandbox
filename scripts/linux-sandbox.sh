#!/usr/bin/env bash
# linux-sandbox.sh — Linux sandbox using bubblewrap
#
# Called by claude-sandbox.sh. Expects these environment variables:
#   _CS_READ_ONLY_PATHS   — newline-delimited list
#   _CS_BLOCKED_PATHS     — newline-delimited list
#   _CS_WRITABLE_PATHS    — newline-delimited list
#   _CS_PROXY_PORT        — TCP port of the egress proxy on the host
#   _CS_WORKSPACE         — workspace directory path
#   _CS_CLAUDE_BIN        — path to the claude binary (may be a symlink)
#   _CS_CLAUDE_BIN_REAL   — resolved real path of the binary
#   _CS_AUDIT_LOG         — path to audit log (in session directory)
#   _CS_SESSION_ID        — unique session identifier
#   _CS_SESSION_DIR       — session directory for logs and context

set -euo pipefail

# ── Read arrays from environment ──────────────────────────────
readarray -t READ_ONLY_PATHS <<< "$_CS_READ_ONLY_PATHS"
readarray -t BLOCKED_PATHS   <<< "$_CS_BLOCKED_PATHS"
readarray -t WRITABLE_PATHS  <<< "$_CS_WRITABLE_PATHS"
readarray -t PASSTHROUGH_ENV <<< "${_CS_PASSTHROUGH_ENV:-}"
readarray -t PORT_FORWARDS  <<< "${_CS_PORT_FORWARDS:-}"

# ── Path Security Utilities ───────────────────────────────────

# Validate path doesn't contain dangerous characters (newlines).
# These could break newline-delimited array IPC.
# Note: Null bytes cannot exist in bash variables (C string termination),
# so no check is needed for them.
# Usage: validate_path_chars "$path" || exit 1
validate_path_chars() {
  local path="$1"
  if [[ "$path" == *$'\n'* ]]; then
    echo "ERROR: Path contains newline character (rejected for security)" >&2
    return 1
  fi
  return 0
}

# Canonicalize a path by resolving all symlinks to physical path.
# Returns exit code 1 on failure - callers MUST check return code.
# Usage: resolved=$(canonicalize_path "$path") || exit 1
canonicalize_path() {
  local path="$1"
  local result

  # Validate characters first
  validate_path_chars "$path" || return 1

  # Handle relative paths (like ".")
  if [[ "$path" != /* ]]; then
    if [[ -d "$path" ]]; then
      result=$(cd "$path" 2>/dev/null && pwd -P) || return 1
      echo "$result"
      return 0
    fi
    # Non-directory relative path: resolve parent, append basename
    local dir base
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if [[ -d "$dir" ]]; then
      result=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
      echo "$result/$base"
      return 0
    fi
    # Parent doesn't exist - cannot resolve
    echo "ERROR: Cannot resolve path (parent does not exist): $path" >&2
    return 1
  fi

  # Absolute path - platform-specific resolution
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS: Use Python for reliable cross-platform resolution
    # SECURITY: Pass path via stdin to prevent command injection
    if result=$(printf '%s' "$path" | python3 -c "import os, sys; print(os.path.realpath(sys.stdin.read()))" 2>/dev/null); then
      echo "$result"
      return 0
    fi
    echo "ERROR: Cannot resolve path on macOS: $path" >&2
    return 1
  else
    # Linux: Use realpath
    # For existing paths, use -e (canonicalize-existing) which fails if path doesn't exist
    # For paths to be created, resolve the existing parent first
    if [[ -e "$path" ]]; then
      if result=$(realpath -e "$path" 2>/dev/null); then
        echo "$result"
        return 0
      fi
      echo "ERROR: Cannot resolve existing path: $path" >&2
      return 1
    else
      # Path doesn't exist - resolve parent, append basename
      local dir base
      dir="$(dirname "$path")"
      base="$(basename "$path")"
      if [[ -e "$dir" ]]; then
        local resolved_dir
        if resolved_dir=$(realpath -e "$dir" 2>/dev/null); then
          echo "$resolved_dir/$base"
          return 0
        fi
      fi
      echo "ERROR: Cannot resolve path (parent does not exist): $path" >&2
      return 1
    fi
  fi
}

# Validate that a resolved path doesn't fall under any blocked path.
# Both candidate and blocked paths must already be resolved.
# Usage: validate_not_blocked "$resolved_path" || exit 1
validate_not_blocked() {
  local resolved="$1"
  local original="${2:-$1}"

  for blocked in "${BLOCKED_PATHS_RESOLVED[@]}"; do
    [[ -z "$blocked" ]] && continue

    # Check exact match or subpath
    if [[ "$resolved" == "$blocked" || "$resolved" == "$blocked"/* ]]; then
      echo "ERROR: Access denied for path: $original" >&2
      return 1
    fi
  done

  return 0
}

# ── Pre-resolve blocked paths for efficient comparison ────────
# Resolve all blocked paths once at startup. If a blocked path doesn't exist,
# we normalize it to an absolute path for consistent comparison.
declare -a BLOCKED_PATHS_RESOLVED=()
for blocked in "${BLOCKED_PATHS[@]}"; do
  [[ -z "$blocked" ]] && continue
  validate_path_chars "$blocked" || {
    echo "ERROR: Blocked path in config contains invalid characters" >&2
    exit 1
  }

  if resolved=$(canonicalize_path "$blocked" 2>/dev/null); then
    BLOCKED_PATHS_RESOLVED+=("$resolved")
  else
    # Path doesn't exist - ensure it's absolute for comparison
    # Expand ~ if present, then store
    normalized="$blocked"
    if [[ "$normalized" == "~"* ]]; then
      normalized="${HOME}${normalized:1}"
    fi
    # If still relative, make it absolute based on HOME
    if [[ "$normalized" != /* ]]; then
      normalized="$HOME/$normalized"
    fi
    BLOCKED_PATHS_RESOLVED+=("$normalized")
  fi
done

# ── Read socket directory from parent ─────────────────────────
# The host-side socat bridge is managed by claude-sandbox.sh so that
# its PID is accessible for cleanup in the parent process.
#
# Full chain:
#   Claude Code → TCP 127.0.0.1:18080 (sandbox socat)
#     → Unix /run/sandbox/proxy.sock (bind-mounted into sandbox)
#     → TCP 127.0.0.1:$PROXY_PORT (host socat)
#     → egress-proxy.py (HTTP CONNECT for HTTPS, or direct for HTTP)
SOCKET_DIR="${_CS_SOCKET_DIR:?ERROR: _CS_SOCKET_DIR not set}"
SOCKET_PATH="$SOCKET_DIR/proxy.sock"

if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "ERROR: proxy socket not found at $SOCKET_PATH" >&2
  exit 1
fi

# ── Locate socat binary (needed inside the sandbox) ──────────
# The Nix flake provides socat. Its store path works inside the sandbox
# since /nix is mounted read-only.
SOCAT_BIN="$(command -v socat)"
if [[ -z "$SOCAT_BIN" ]]; then
  echo "ERROR: socat not found in PATH." >&2
  exit 1
fi

# ── Locate sleep binary (needed inside the sandbox on NixOS) ─
SLEEP_BIN="$(command -v sleep)"

# ── Resolve Claude binary ───────────────────────────────────
CLAUDE_BIN_REAL="${_CS_CLAUDE_BIN_REAL:-$(readlink -f "$_CS_CLAUDE_BIN")}"

# ── Create sandbox entry script ──────────────────────────────
# Claude Code doesn't support socks5h://unix: proxy URLs.
# It needs a standard HTTP proxy at http://127.0.0.1:PORT.
#
# Inside --unshare-net there's no network (not even loopback).
# The entry script runs INSIDE the sandbox and:
#   1. Brings up the loopback interface (allowed by CAP_NET_ADMIN in user ns)
#   2. Starts socat to bridge TCP:18080 → Unix socket → host proxy
#   3. Execs Claude Code

# ── Resolve NixOS system path for sandbox PATH ───────────────
# On NixOS, /run/current-system/sw/bin is a symlink to a /nix/store path.
# Inside the sandbox /run is not mounted, so resolve it now to the real
# store path (which IS accessible via --ro-bind /nix /nix).
if [[ -d /run/current-system/sw/bin ]]; then
  _CS_NIXOS_SYSTEM_PATH="$(readlink -f /run/current-system/sw/bin)"
else
  _CS_NIXOS_SYSTEM_PATH="/run/current-system/sw/bin"
fi

# ── Extract Nix store paths from current PATH ────────────────
# The Nix flake provides tools (bwrap, socat, node, etc.) via /nix/store
# paths. Claude Code's internal sandbox needs bwrap on PATH. Since /nix
# is mounted read-only inside the sandbox, these store paths are accessible
# — they just need to be in PATH. Extract them at generation time so
# they're baked into the entry script.
_CS_NIX_STORE_PATH=$(echo "$PATH" | tr ':' '\n' | grep '^/nix/store' | paste -sd ':')

INTERNAL_PROXY_PORT=18080
ENTRY_SCRIPT="$SOCKET_DIR/entry.sh"

# Pre-generate port-forward socat lines for the entry script
_PF_LINES=""
for port in "${PORT_FORWARDS[@]}"; do
  [[ -z "$port" ]] && continue
  # Defense-in-depth: re-validate even though parent already checked
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
    echo "WARNING: Skipping invalid port_forwards entry in entry script: '$port'" >&2
    continue
  fi
  _PF_LINES+="$SOCAT_BIN TCP-LISTEN:${port},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/sandbox/pf-${port}.sock 2>/dev/null &"$'\n'
done

cat > "$ENTRY_SCRIPT" <<ENTRY_EOF
#!/bin/sh
# --- Sandbox entry point (runs inside bubblewrap) ---

# Set PATH here rather than via bwrap --setenv PATH, which triggers an
# execvp ENOENT bug when PATH contains dirs absent from the sandbox
# (e.g. /run/current-system/sw/bin on NixOS where /run is not mounted).
# On NixOS, /run/current-system/sw/bin is a symlink into /nix/store —
# resolve it at generation time so the real store path lands in PATH.
# Nix store paths are appended so flake-provided tools (bwrap, etc.)
# are available inside the sandbox.
export PATH="/usr/bin:/bin:/usr/local/bin:${HOME}/.local/bin:/nix/var/nix/profiles/default/bin:${_CS_NIXOS_SYSTEM_PATH}:${_CS_NIX_STORE_PATH}"

# 1. Bring up loopback interface in the network namespace
#    bwrap's --unshare-net creates a net ns with lo DOWN.
#    We have CAP_NET_ADMIN via the user namespace, so we can bring it up.
if ! /usr/sbin/ip link set lo up 2>/dev/null; then
  ip link set lo up 2>/dev/null || true
fi

# 2. Start TCP→Unix bridge so Claude Code can reach the proxy
#    This listens on 127.0.0.1:18080 and forwards to /run/sandbox/proxy.sock
#    NOTE: This socat runs inside bwrap's network namespace. When bwrap exits,
#    the network namespace is destroyed, causing this process to self-terminate.
#    No explicit cleanup is needed from the host side.
$SOCAT_BIN TCP-LISTEN:$INTERNAL_PROXY_PORT,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/sandbox/proxy.sock 2>>"$_CS_SESSION_DIR/socat-sandbox.log" &

# 2b. Port-forward bridges (host services accessible from sandbox)
${_PF_LINES}

# Give the bridges a moment to start
$SLEEP_BIN 0.3

# 3. Preserve nix store paths for child shells.
#    On NixOS, /etc/zsh/zshenv replaces PATH with system defaults, losing
#    the nix store paths set above. Claude Code uses zsh for its Bash tool,
#    so tools like bwrap (needed for Claude's internal sandbox) become
#    unfindable. Fix: create ~/.zshenv that re-adds nix store paths after
#    NixOS system init. User zshenv runs AFTER /etc/zsh/zshenv.
echo 'export PATH="${_CS_NIX_STORE_PATH}:\$PATH"' > "\$HOME/.zshenv"

# 4. Pre-create Claude Code's sandbox temp directory.
#    Claude Code's internal bwrap needs /tmp/claude-<UID> to exist in the
#    outer mount namespace for bind mounts and CWD tracking. Inside our
#    external bwrap, /tmp is a fresh tmpfs — create the directory so the
#    inner bwrap can use it as a mount point and CWD tracking target.
mkdir -p "/tmp/claude-\$(id -u)" 2>/dev/null || true

# 5. Exec Claude Code with all arguments
exec $CLAUDE_BIN_REAL "\$@"
ENTRY_EOF
chmod +x "$ENTRY_SCRIPT"

# ── Build bwrap argument list ─────────────────────────────────

BWRAP_ARGS=()
BASE_MOUNTS=()

# --- Base filesystem ---
# Modern distros (Debian Bookworm, Fedora 34+, Ubuntu 24+) use "usr-merge":
#   /bin → usr/bin, /lib → usr/lib, /sbin → usr/sbin
#
# bubblewrap's --ro-bind follows symlinks for the SOURCE but creates a
# real DIRECTORY at the destination. This breaks ELF binaries because
# the kernel's dynamic linker expects /lib/ld-linux-*.so.1 to resolve
# through the same path structure as the host.
#
# Fix: on usr-merged systems, mount /usr and recreate symlinks.

if [[ -L /lib ]]; then
  # ── usr-merged system (Debian Bookworm, Raspberry Pi OS, etc.) ──
  BWRAP_ARGS+=(--ro-bind /usr /usr)
  BASE_MOUNTS+=(/usr)
  [[ -L /bin ]]   && BWRAP_ARGS+=(--symlink usr/bin /bin)   && BASE_MOUNTS+=(/bin)
  [[ -L /sbin ]]  && BWRAP_ARGS+=(--symlink usr/sbin /sbin) && BASE_MOUNTS+=(/sbin)
  [[ -L /lib ]]   && BWRAP_ARGS+=(--symlink usr/lib /lib)   && BASE_MOUNTS+=(/lib)
  [[ -L /lib64 ]] && BWRAP_ARGS+=(--symlink usr/lib64 /lib64) && BASE_MOUNTS+=(/lib64)
  [[ -d /lib64 ]] && [[ ! -L /lib64 ]] && BWRAP_ARGS+=(--ro-bind /lib64 /lib64) && BASE_MOUNTS+=(/lib64)
else
  # ── Traditional layout (NixOS, older distros) ──
  for base in /usr /bin /lib /sbin; do
    [[ -e "$base" ]] && BWRAP_ARGS+=(--ro-bind "$base" "$base") && BASE_MOUNTS+=("$base")
  done
  [[ -e /lib64 ]] && BWRAP_ARGS+=(--ro-bind /lib64 /lib64) && BASE_MOUNTS+=(/lib64)
fi

# Dynamic linker config
for etc_path in /etc/ld.so.cache /etc/ld.so.conf /etc/ld.so.conf.d; do
  [[ -e "$etc_path" ]] && BWRAP_ARGS+=(--ro-bind "$etc_path" "$etc_path")
done

# /etc — mount entire directory read-only for system config (resolv.conf,
# ssl certs, passwd, hostname, etc). Blocked paths (e.g. /etc/shadow)
# override this later with --ro-bind /dev/null.
[[ -d /etc ]] && BWRAP_ARGS+=(--ro-bind /etc /etc) && BASE_MOUNTS+=(/etc)

# Nix store
[[ -d /nix ]] && BWRAP_ARGS+=(--ro-bind /nix /nix) && BASE_MOUNTS+=(/nix)

# /proc, /dev, ephemeral /tmp
BWRAP_ARGS+=(
  --proc /proc
  --dev  /dev
  --tmpfs /tmp
)
BASE_MOUNTS+=(/proc /dev /tmp)

# Home directory structure for bind mounts
# bwrap requires parent directories to exist before mounting inside them.
# Create /home as tmpfs, then user's home dir inside it.
# Actual home contents come from selective bind mounts below.
# NOTE: We don't add $HOME to BASE_MOUNTS because we DO want to mount
# things inside it (like ~/.gitconfig). Only /home is "base".
BWRAP_ARGS+=(--tmpfs /home)
BWRAP_ARGS+=(--dir "$HOME")

# --- Profile: read-only mounts ---
# Skip paths that are already covered by base mounts (exact match or sub-path).
# These are redundant, and on NixOS re-mounting symlinks (like /etc/hosts)
# inside a read-only bind mount causes bwrap to fail.
for path in "${READ_ONLY_PATHS[@]}"; do
  [[ -z "$path" ]] && continue
  skip=0
  for base in "${BASE_MOUNTS[@]}"; do
    if [[ "$path" == "$base" || "$path" == "$base"/* ]]; then
      skip=1; break
    fi
  done
  [[ "$skip" -eq 1 ]] && continue
  [[ -e "$path" ]] && BWRAP_ARGS+=(--ro-bind "$path" "$path")
done

# --- Profile: blocked paths ---
for path in "${BLOCKED_PATHS[@]}"; do
  [[ -z "$path" ]] && continue
  if [[ -d "$path" ]]; then
    BWRAP_ARGS+=(--tmpfs "$path")
  elif [[ -f "$path" ]]; then
    BWRAP_ARGS+=(--ro-bind /dev/null "$path")
  fi
done

# --- Profile: writable mounts ---
# Store original resolutions for TOCTOU verification later
declare -a WRITABLE_PATHS_RESOLVED=()
declare -a WRITABLE_PATHS_ORIGINAL=()

for path in "${WRITABLE_PATHS[@]}"; do
  [[ -z "$path" ]] && continue

  # Validate path characters
  validate_path_chars "$path" || {
    echo "ERROR: Writable path contains invalid characters: refusing to proceed" >&2
    exit 1
  }

  original_path="$path"
  resolved_path=""

  # Resolve to physical path
  if ! resolved_path=$(canonicalize_path "$path"); then
    echo "ERROR: Cannot resolve writable path '$original_path'" >&2
    exit 1
  fi

  # Validate resolved path is not under a blocked path
  if ! validate_not_blocked "$resolved_path" "$original_path"; then
    echo "ERROR: Writable path resolves to blocked location - refusing to mount" >&2
    exit 1
  fi

  # Store for TOCTOU verification
  WRITABLE_PATHS_ORIGINAL+=("$original_path")
  WRITABLE_PATHS_RESOLVED+=("$resolved_path")

  mkdir -p "$resolved_path" 2>/dev/null || true
  BWRAP_ARGS+=(--bind "$resolved_path" "$resolved_path")
done

# --- Claude Code binary ---
CLAUDE_BIN_DIR="$(dirname "$CLAUDE_BIN_REAL")"
CLAUDE_TREE="$CLAUDE_BIN_DIR"
case "$(basename "$CLAUDE_TREE")" in
  versions|node_modules) CLAUDE_TREE="$(dirname "$CLAUDE_TREE")" ;;
esac
case "$CLAUDE_TREE" in
  /usr/*|/bin/*|/lib/*|/nix/*|.) ;;  # Skip system paths and "." (shell builtins)
  *) [[ -d "$CLAUDE_TREE" ]] && BWRAP_ARGS+=(--ro-bind "$CLAUDE_TREE" "$CLAUDE_TREE") ;;
esac

# If Claude is a script, mount its interpreter tree
if [[ -f "$CLAUDE_BIN_REAL" ]] && head -c 2 "$CLAUDE_BIN_REAL" 2>/dev/null | grep -q '^#!'; then
  SHEBANG_LINE="$(head -1 "$CLAUDE_BIN_REAL")"
  INTERP_PATH="$(echo "$SHEBANG_LINE" | sed 's/^#!//' | awk '{print $1}')"
  if [[ "$INTERP_PATH" == "/usr/bin/env" ]]; then
    INTERP_PROG="$(echo "$SHEBANG_LINE" | awk '{print $2}')"
    INTERP_PATH="$(command -v "$INTERP_PROG" 2>/dev/null || true)"
  fi
  if [[ -n "$INTERP_PATH" ]] && [[ -e "$INTERP_PATH" ]]; then
    INTERP_REAL="$(readlink -f "$INTERP_PATH")"
    INTERP_DIR="$(dirname "$INTERP_REAL")"
    if [[ "$(basename "$INTERP_DIR")" == "bin" ]]; then
      INTERP_ROOT="$(dirname "$INTERP_DIR")"
    else
      INTERP_ROOT="$INTERP_DIR"
    fi
    case "$INTERP_ROOT" in
      /usr/*|/bin/*|/lib/*|/nix/*) ;;
      *) [[ -d "$INTERP_ROOT" ]] && BWRAP_ARGS+=(--ro-bind "$INTERP_ROOT" "$INTERP_ROOT") ;;
    esac
  fi
fi

# --- Claude Code configuration ---
# Claude Code needs WRITE access to ~/.claude for session state, todos, logs.
# Auth tokens are stored here too — this is acceptable since the sandbox
# already trusts Claude Code to make API calls.
CLAUDE_CONFIG="${HOME}/.claude"
CLAUDE_CONFIG_ALT="${HOME}/.config/claude"
CLAUDE_JSON="${HOME}/.claude.json"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# Ensure settings.json exists on HOST (prevents creation inside sandbox)
# This file contains security-critical deny rules that must be protected
if [[ ! -d "$CLAUDE_CONFIG" ]]; then
  mkdir -p "$CLAUDE_CONFIG" 2>/dev/null || true
fi
if [[ -d "$CLAUDE_CONFIG" && ! -f "$SETTINGS_FILE" ]]; then
  echo '{}' > "$SETTINGS_FILE" 2>/dev/null || true
fi

[[ -d "$CLAUDE_CONFIG" ]]     && BWRAP_ARGS+=(--bind "$CLAUDE_CONFIG" "$CLAUDE_CONFIG")
# Protect settings.json from modification (must come AFTER the ~/.claude bind)
# This prevents prompt injection from removing deny rules
[[ -f "$SETTINGS_FILE" ]]     && BWRAP_ARGS+=(--ro-bind "$SETTINGS_FILE" "$SETTINGS_FILE")
[[ -d "$CLAUDE_CONFIG_ALT" ]] && BWRAP_ARGS+=(--bind "$CLAUDE_CONFIG_ALT" "$CLAUDE_CONFIG_ALT")
# ~/.claude.json holds oauthAccount binding (accountUuid, organizationUuid).
# Without it, interactive mode can't identify the user and shows the login screen.
[[ -f "$CLAUDE_JSON" ]]       && BWRAP_ARGS+=(--bind "$CLAUDE_JSON" "$CLAUDE_JSON")

# Workspace — mounted by the writable paths loop above (via profile config).
# The launcher (claude-sandbox.sh) always injects $_CS_WORKSPACE into
# _CS_WRITABLE_PATHS, so it's guaranteed to be covered.

# --- Network isolation + proxy bridge ---
# Mount the socket directory as a whole rather than individual files.
# bwrap --ro-bind of individual files fails on some systems (e.g. NixOS).
BWRAP_ARGS+=(
  --unshare-net
  --unshare-pid
  --die-with-parent
  --ro-bind "$SOCKET_DIR" /run/sandbox
)

# ── Environment isolation: clear all, then whitelist ─────────
BWRAP_ARGS+=(--clearenv)

BWRAP_ARGS+=(
  --setenv HOME   "$HOME"
  --setenv USER   "${USER:-claude}"
  --setenv LANG   "${LANG:-C.UTF-8}"
  --setenv TERM   "${TERM:-xterm-256color}"
  --setenv TMPDIR "/tmp"
  --setenv HTTP_PROXY  "http://127.0.0.1:${INTERNAL_PROXY_PORT}"
  --setenv HTTPS_PROXY "http://127.0.0.1:${INTERNAL_PROXY_PORT}"
  --setenv ALL_PROXY   "http://127.0.0.1:${INTERNAL_PROXY_PORT}"
  # NO_PROXY bypasses egress proxy for localhost. Safe because --unshare-net
  # creates an empty network namespace — only explicitly bridged ports (via
  # socat in entry.sh) are reachable on 127.0.0.1 inside the sandbox.
  --setenv NO_PROXY    "127.0.0.1,localhost"
  --setenv CLAUDE_SANDBOX_WORKSPACE "$_CS_WORKSPACE"
)

# XDG dirs if set (Claude Code may need these)
[[ -n "${XDG_CONFIG_HOME:-}" ]] && BWRAP_ARGS+=(--setenv XDG_CONFIG_HOME "$XDG_CONFIG_HOME")
[[ -n "${XDG_DATA_HOME:-}" ]]   && BWRAP_ARGS+=(--setenv XDG_DATA_HOME "$XDG_DATA_HOME")
[[ -n "${XDG_CACHE_HOME:-}" ]]  && BWRAP_ARGS+=(--setenv XDG_CACHE_HOME "$XDG_CACHE_HOME")

# Pass auth tokens if set (intentionally passed through)
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && BWRAP_ARGS+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && BWRAP_ARGS+=(--setenv CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN")

# Pass through profile-configured env vars (for MCP support)
for var in "${PASSTHROUGH_ENV[@]}"; do
  [[ -n "$var" && -n "${!var:-}" ]] && BWRAP_ARGS+=(--setenv "$var" "${!var}")
done

# --- Working directory ---
# Determine if CWD is accessible inside the sandbox and set --chdir appropriately.
# Must be done after writable paths are processed.
determine_cwd() {
  local cwd_logical cwd_resolved blocked wpath_resolved

  cwd_logical="$(pwd)"
  if ! cwd_resolved=$(canonicalize_path "$cwd_logical"); then
    echo "WARNING: Cannot resolve current directory, using workspace" >&2
    BWRAP_ARGS+=(--chdir "$_CS_WORKSPACE")
    return
  fi

  local cwd_accessible=1

  # Check if CWD is under a blocked path
  for blocked in "${BLOCKED_PATHS_RESOLVED[@]}"; do
    [[ -z "$blocked" ]] && continue
    if [[ "$cwd_resolved" == "$blocked" || "$cwd_resolved" == "$blocked"/* ]]; then
      cwd_accessible=0
      # Check if overridden by writable path
      for wpath_resolved in "${WRITABLE_PATHS_RESOLVED[@]}"; do
        [[ -z "$wpath_resolved" ]] && continue
        if [[ "$cwd_resolved" == "$wpath_resolved" || "$cwd_resolved" == "$wpath_resolved"/* ]]; then
          cwd_accessible=1
          break
        fi
      done
      break
    fi
  done

  if [[ "$cwd_accessible" == "0" ]]; then
    echo "WARNING: Current directory is under blocked path, using workspace" >&2
    BWRAP_ARGS+=(--chdir "$_CS_WORKSPACE")
  else
    # SUCCESS CASE: Use the resolved physical path as CWD
    # This is the key fix for the symlink CWD issue
    BWRAP_ARGS+=(--chdir "$cwd_resolved")
  fi
}

determine_cwd

# --- Exec via entry script ---
# The entry script brings up loopback, starts the TCP→Unix bridge,
# then execs Claude Code. This is needed because --unshare-net kills
# all networking, and we need loopback for the HTTP proxy.
BWRAP_ARGS+=(-- /run/sandbox/entry.sh)

# ── Final validation before exec (TOCTOU mitigation) ──────────
# Re-validate critical paths immediately before exec.
# Compare against stored original resolutions to detect symlink swaps.
verify_paths_stable() {
  local i=0
  for original_path in "${WRITABLE_PATHS_ORIGINAL[@]}"; do
    [[ -z "$original_path" ]] && { ((i++)) || true; continue; }

    local current_resolved expected_resolved
    expected_resolved="${WRITABLE_PATHS_RESOLVED[$i]}"

    if ! current_resolved=$(canonicalize_path "$original_path" 2>/dev/null); then
      echo "ERROR: Path disappeared before sandbox start: $original_path" >&2
      return 1
    fi

    # CRITICAL: Compare against original resolution to detect symlink swaps
    if [[ "$current_resolved" != "$expected_resolved" ]]; then
      echo "ERROR: Path resolution changed (was: $expected_resolved, now: $current_resolved)" >&2
      echo "ERROR: Possible symlink race attack detected" >&2
      return 1
    fi

    # Also verify still not blocked (belt and suspenders)
    if ! validate_not_blocked "$current_resolved" "$original_path"; then
      echo "ERROR: Path now resolves to blocked location: $original_path" >&2
      return 1
    fi

    ((i++)) || true
  done
  return 0
}

if ! verify_paths_stable; then
  echo "ERROR: Path validation failed - refusing to start sandbox" >&2
  exit 1
fi

echo "  Launching Claude Code in bubblewrap sandbox..."

# Debug: show full bwrap command if CLAUDE_SANDBOX_DEBUG=1
if [[ "${CLAUDE_SANDBOX_DEBUG:-}" == "1" ]]; then
  echo ""
  echo "  [DEBUG] Claude binary (symlink): $_CS_CLAUDE_BIN"
  echo "  [DEBUG] Claude binary (real):    $CLAUDE_BIN_REAL"
  echo "  [DEBUG] Socat binary:            $SOCAT_BIN"
  echo "  [DEBUG] Internal proxy port:     $INTERNAL_PROXY_PORT"
  echo "  [DEBUG] usr-merge detected:      $([[ -L /lib ]] && echo yes || echo no)"
  echo "  [DEBUG] Full bwrap command:"
  printf "    bwrap"
  for arg in "${BWRAP_ARGS[@]}"; do
    printf " %q" "$arg"
  done
  printf " %s\n" "$*"
  echo ""
  echo "  [DEBUG] Entry script contents:"
  cat "$ENTRY_SCRIPT" | sed 's/^/    /'
  echo ""
fi

echo ""
exec bwrap "${BWRAP_ARGS[@]}" "$@"
