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

# ── Set up socat bridge (host side) ──────────────────────────
# bubblewrap's --unshare-net creates a completely empty network namespace.
# We use a Unix socket as the sole communication channel between the
# sandbox and the host. On the host side, socat bridges this socket to
# the egress proxy's TCP port.
#
# Full chain:
#   Claude Code → TCP 127.0.0.1:18080 (sandbox socat)
#     → Unix /run/sandbox/proxy.sock (bind-mounted into sandbox)
#     → TCP 127.0.0.1:$PROXY_PORT (host socat)
#     → egress-proxy.py (HTTP CONNECT for HTTPS, or direct for HTTP)

SOCKET_DIR=$(mktemp -d /tmp/claude-sandbox-sock.XXXXXX)
SOCKET_PATH="$SOCKET_DIR/proxy.sock"

socat "UNIX-LISTEN:${SOCKET_PATH},fork,mode=777" "TCP:127.0.0.1:${_CS_PROXY_PORT}" &
SOCAT_PID=$!
export SOCAT_PID

sleep 0.3

if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "ERROR: socat failed to create socket at $SOCKET_PATH" >&2
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

INTERNAL_PROXY_PORT=18080
ENTRY_SCRIPT="$SOCKET_DIR/entry.sh"
cat > "$ENTRY_SCRIPT" <<ENTRY_EOF
#!/bin/sh
# --- Sandbox entry point (runs inside bubblewrap) ---

# Set PATH here rather than via bwrap --setenv PATH, which triggers an
# execvp ENOENT bug when PATH contains dirs absent from the sandbox
# (e.g. /run/current-system/sw/bin on NixOS where /run is not mounted).
# On NixOS, /run/current-system/sw/bin is a symlink into /nix/store —
# resolve it at generation time so the real store path lands in PATH.
export PATH="/usr/bin:/bin:/usr/local/bin:${HOME}/.local/bin:/nix/var/nix/profiles/default/bin:${_CS_NIXOS_SYSTEM_PATH}"

# 1. Bring up loopback interface in the network namespace
#    bwrap's --unshare-net creates a net ns with lo DOWN.
#    We have CAP_NET_ADMIN via the user namespace, so we can bring it up.
if ! /usr/sbin/ip link set lo up 2>/dev/null; then
  ip link set lo up 2>/dev/null || true
fi

# 2. Start TCP→Unix bridge so Claude Code can reach the proxy
#    This listens on 127.0.0.1:18080 and forwards to /run/sandbox/proxy.sock
$SOCAT_BIN TCP-LISTEN:$INTERNAL_PROXY_PORT,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/sandbox/proxy.sock &

# Give the bridge a moment to start
$SLEEP_BIN 0.3

# 3. Exec Claude Code with all arguments
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
for path in "${WRITABLE_PATHS[@]}"; do
  [[ -z "$path" ]] && continue
  # Resolve relative paths (e.g., "." from config)
  if [[ "$path" != /* ]]; then
    path="$(cd "$path" 2>/dev/null && pwd || echo "$path")"
  fi
  mkdir -p "$path" 2>/dev/null || true
  BWRAP_ARGS+=(--bind "$path" "$path")
done

# --- Claude Code binary ---
CLAUDE_BIN_DIR="$(dirname "$CLAUDE_BIN_REAL")"
CLAUDE_TREE="$CLAUDE_BIN_DIR"
case "$(basename "$CLAUDE_TREE")" in
  versions|node_modules) CLAUDE_TREE="$(dirname "$CLAUDE_TREE")" ;;
esac
case "$CLAUDE_TREE" in
  /usr/*|/bin/*|/lib/*|/nix/*) ;;
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
[[ -d "$CLAUDE_CONFIG" ]]     && BWRAP_ARGS+=(--bind "$CLAUDE_CONFIG" "$CLAUDE_CONFIG")
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
  --ro-bind "$SOCKET_DIR" /run/sandbox
)

# --- Environment ---
BWRAP_ARGS+=(
  --setenv HOME   "$HOME"
  --setenv USER   "${USER:-claude}"
  --setenv LANG   "${LANG:-C.UTF-8}"
  --setenv TERM   "${TERM:-xterm-256color}"
  --setenv TMPDIR "/tmp"

  # Standard HTTP proxy format — Claude Code sends CONNECT for HTTPS
  --setenv HTTP_PROXY  "http://127.0.0.1:${INTERNAL_PROXY_PORT}"
  --setenv HTTPS_PROXY "http://127.0.0.1:${INTERNAL_PROXY_PORT}"
  --setenv ALL_PROXY   "http://127.0.0.1:${INTERNAL_PROXY_PORT}"
  --setenv NO_PROXY    ""

  --setenv CLAUDE_SANDBOX_WORKSPACE "$_CS_WORKSPACE"
)

# --- Working directory ---
# If the cwd is under a blocked path (e.g. ~ in strict profile) and not
# overridden by a writable mount, it won't exist in the sandbox. Without
# --chdir, bwrap would land in / or an empty tmpfs. Fall back to the
# workspace so Claude starts somewhere usable.
_cwd="$(pwd)"
_cwd_accessible=1
for path in "${BLOCKED_PATHS[@]}"; do
  [[ -z "$path" ]] && continue
  if [[ "$_cwd" == "$path" || "$_cwd" == "$path"/* ]]; then
    _cwd_accessible=0
    for wpath in "${WRITABLE_PATHS[@]}"; do
      [[ -z "$wpath" ]] && continue
      if [[ "$wpath" != /* ]]; then
        wpath="$(cd "$wpath" 2>/dev/null && pwd || echo "$wpath")"
      fi
      if [[ "$_cwd" == "$wpath" || "$_cwd" == "$wpath"/* ]]; then
        _cwd_accessible=1
        break
      fi
    done
    break
  fi
done
if [[ "$_cwd_accessible" == "0" ]]; then
  BWRAP_ARGS+=(--chdir "$_CS_WORKSPACE")
fi

# --- Exec via entry script ---
# The entry script brings up loopback, starts the TCP→Unix bridge,
# then execs Claude Code. This is needed because --unshare-net kills
# all networking, and we need loopback for the HTTP proxy.
BWRAP_ARGS+=(-- /run/sandbox/entry.sh)

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
