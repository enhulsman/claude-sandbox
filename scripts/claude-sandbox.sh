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
#                  CLAUDE_SANDBOX_YOLO, CLAUDE_SANDBOX_TOKEN_FILE
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
      CLAUDE_SANDBOX_TOKEN_FILE)
        _CS_TOKEN_FILE="${CLAUDE_SANDBOX_TOKEN_FILE:-$_val}" ;;
    esac
  done < "$_CS_DEFAULTS_FILE"
fi

# ── Load Token File ────────────────────────────────────────────
# Automatically source a token file for headless/Pi authentication.
# Supports ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN exports.
_CS_TOKEN_FILE="${CLAUDE_SANDBOX_TOKEN_FILE:-${_CS_TOKEN_FILE:-$HOME/.claude-sandbox-token}}"

if [[ -f "$_CS_TOKEN_FILE" ]]; then
  # Security: warn if loose permissions (600 = owner read/write only)
  _perms=$(stat -c %a "$_CS_TOKEN_FILE" 2>/dev/null || stat -f %Lp "$_CS_TOKEN_FILE" 2>/dev/null)
  if [[ "$_perms" != "600" ]]; then
    echo "WARNING: $_CS_TOKEN_FILE has loose permissions ($_perms). Run: chmod 600 '$_CS_TOKEN_FILE'" >&2
  fi
  # shellcheck source=/dev/null
  source "$_CS_TOKEN_FILE"
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
       claude-sandbox sessions [list|clean] [OPTIONS]

Options:
  --profile PROFILE   Security profile (default: dev)
  --workspace DIR     Writable workspace directory (default: ~/claude-workspace)
  --config FILE       Path to config.toml
  --exec CMD [ARGS]   Run CMD instead of Claude Code (for testing/verify)
  --shell             Shortcut for --exec bash (interactive shell in sandbox)
  --yolo              Pass --dangerously-skip-permissions to Claude Code
                      (safe when using the external sandbox as the boundary)
  --skip-git-check    Skip uncommitted changes check (dev profile only)
  --dry-run           Show what would be done without executing
  -h, --help          Show this help

Subcommands:
  sessions            List all sessions (alias: sessions list)
  sessions clean      Interactive session cleanup
    --days N          Remove sessions older than N days
    --oldest N        Remove the N oldest sessions
    --all             Remove all sessions
    --yes             Skip confirmation prompt

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
  claude-sandbox sessions                                   # list sessions
  claude-sandbox sessions clean --days 7                    # cleanup old sessions
  claude-sandbox sessions clean --oldest 5                  # remove 5 oldest
EOF
  exit 0
}

# ── Sessions Subcommand ───────────────────────────────────────
sessions_cmd() {
  local sessions_dir="$WORKSPACE/.sessions"
  local action="${1:-list}"
  shift || true

  # Ensure workspace exists
  mkdir -p "$WORKSPACE"

  # Parse clean subcommand options
  local days="" oldest="" all=0 yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days)   days="$2"; shift 2 ;;
      --oldest) oldest="$2"; shift 2 ;;
      --all)    all=1; shift ;;
      --yes|-y) yes=1; shift ;;
      -h|--help) sessions_usage; exit 0 ;;
      list)     action="list"; shift ;;
      clean)    action="clean"; shift ;;
      *)        echo "Unknown option: $1" >&2; sessions_usage; exit 1 ;;
    esac
  done

  case "$action" in
    list)  sessions_list "$sessions_dir" ;;
    clean) sessions_clean "$sessions_dir" "$days" "$oldest" "$all" "$yes" ;;
    *)     echo "Unknown action: $action" >&2; sessions_usage; exit 1 ;;
  esac
}

sessions_usage() {
  cat <<'EOF'
Usage: claude-sandbox sessions [list|clean] [OPTIONS]

Commands:
  list              List all sessions (default)
  clean             Clean up old sessions

Clean options:
  --days N          Remove sessions older than N days
  --oldest N        Remove the N oldest sessions
  --all             Remove all sessions
  --yes, -y         Skip confirmation prompt

Examples:
  claude-sandbox sessions                    # list all sessions
  claude-sandbox sessions list               # same as above
  claude-sandbox sessions clean              # interactive cleanup
  claude-sandbox sessions clean --days 7     # remove older than 7 days
  claude-sandbox sessions clean --oldest 3   # remove 3 oldest sessions
  claude-sandbox sessions clean --all --yes  # remove all without prompting
EOF
}

sessions_list() {
  local sessions_dir="$1"

  if [[ ! -d "$sessions_dir" ]]; then
    echo "No sessions found."
    echo "Sessions directory: $sessions_dir"
    return 0
  fi

  # Get current session symlink target
  local current=""
  if [[ -L "$sessions_dir/current" ]]; then
    current=$(readlink "$sessions_dir/current")
  fi

  # Collect session info
  local total_size=0 count=0
  local sessions=()

  while IFS= read -r -d '' dir; do
    local name=$(basename "$dir")
    local size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    local size_bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
    local mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null)
    local age=$(( ($(date +%s) - mtime) / 86400 ))
    local age_str
    if [[ $age -eq 0 ]]; then
      age_str="today"
    elif [[ $age -eq 1 ]]; then
      age_str="1 day ago"
    else
      age_str="$age days ago"
    fi

    local marker=""
    [[ "$name" == "$current" ]] && marker=" (current)"

    sessions+=("$mtime|$name|$age_str|$size|$marker")
    total_size=$((total_size + size_bytes))
    ((count++)) || true
  done < <(find "$sessions_dir" -maxdepth 1 -type d -name "[0-9]*-[0-9]*" -print0 2>/dev/null | sort -z)

  if [[ $count -eq 0 ]]; then
    echo "No sessions found."
    echo "Sessions directory: $sessions_dir"
    return 0
  fi

  # Format total size
  local total_size_h
  if [[ $total_size -gt 1073741824 ]]; then
    total_size_h="$(echo "scale=1; $total_size / 1073741824" | bc)G"
  elif [[ $total_size -gt 1048576 ]]; then
    total_size_h="$(echo "scale=1; $total_size / 1048576" | bc)M"
  elif [[ $total_size -gt 1024 ]]; then
    total_size_h="$(echo "scale=1; $total_size / 1024" | bc)K"
  else
    total_size_h="${total_size}B"
  fi

  echo ""
  echo "Sessions in $sessions_dir/"
  echo "────────────────────────────────────────────────────────────"
  printf "  %-25s %-15s %8s\n" "SESSION" "AGE" "SIZE"
  echo "────────────────────────────────────────────────────────────"

  # Sort by mtime (oldest first) and display
  for entry in $(printf '%s\n' "${sessions[@]}" | sort -t'|' -k1 -n); do
    IFS='|' read -r _ name age_str size marker <<< "$entry"
    printf "  %-25s %-15s %8s%s\n" "$name" "$age_str" "$size" "$marker"
  done

  echo "────────────────────────────────────────────────────────────"
  echo "  $count session(s), $total_size_h total"
  echo ""
}

sessions_clean() {
  local sessions_dir="$1"
  local days="$2"
  local oldest="$3"
  local all="$4"
  local yes="$5"

  if [[ ! -d "$sessions_dir" ]]; then
    echo "No sessions to clean."
    return 0
  fi

  # SECURITY: Sanity check path
  if [[ ! "$sessions_dir" =~ ^$HOME/[^/]+/\.sessions$ && ! "$sessions_dir" =~ ^$HOME/claude-workspace/\.sessions$ ]]; then
    echo "ERROR: Sessions directory outside expected path: $sessions_dir" >&2
    return 1
  fi

  # Get current session to protect it
  local current=""
  if [[ -L "$sessions_dir/current" ]]; then
    current=$(readlink "$sessions_dir/current")
  fi

  # Collect all sessions sorted by mtime (oldest first)
  local sessions=()
  while IFS= read -r -d '' dir; do
    local name=$(basename "$dir")
    local mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null)
    sessions+=("$mtime|$name|$dir")
  done < <(find "$sessions_dir" -maxdepth 1 -type d -name "[0-9]*-[0-9]*" -print0 2>/dev/null)

  # Sort by mtime
  IFS=$'\n' sessions=($(printf '%s\n' "${sessions[@]}" | sort -t'|' -k1 -n))
  unset IFS

  local total=${#sessions[@]}
  if [[ $total -eq 0 ]]; then
    echo "No sessions to clean."
    return 0
  fi

  # Determine which sessions to remove
  local to_remove=()

  if [[ "$all" == "1" ]]; then
    # Remove all (except current)
    for entry in "${sessions[@]}"; do
      IFS='|' read -r _ name dir <<< "$entry"
      [[ "$name" != "$current" ]] && to_remove+=("$dir")
    done
  elif [[ -n "$oldest" ]]; then
    # Remove N oldest (except current)
    local count=0
    for entry in "${sessions[@]}"; do
      [[ $count -ge $oldest ]] && break
      IFS='|' read -r _ name dir <<< "$entry"
      if [[ "$name" != "$current" ]]; then
        to_remove+=("$dir")
        ((count++)) || true
      fi
    done
  elif [[ -n "$days" ]]; then
    # Remove older than N days (except current)
    local cutoff=$(($(date +%s) - days * 86400))
    for entry in "${sessions[@]}"; do
      IFS='|' read -r mtime name dir <<< "$entry"
      if [[ $mtime -lt $cutoff && "$name" != "$current" ]]; then
        to_remove+=("$dir")
      fi
    done
  else
    # Interactive mode
    sessions_list "$sessions_dir"
    sessions_clean_interactive "$sessions_dir" "$current" "${sessions[@]}"
    return $?
  fi

  local remove_count=${#to_remove[@]}
  if [[ $remove_count -eq 0 ]]; then
    echo "No sessions match the criteria."
    return 0
  fi

  # Calculate size to be freed
  local remove_size=0
  for dir in "${to_remove[@]}"; do
    local size_bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
    remove_size=$((remove_size + size_bytes))
  done
  local remove_size_h
  if [[ $remove_size -gt 1048576 ]]; then
    remove_size_h="$(echo "scale=1; $remove_size / 1048576" | bc)M"
  elif [[ $remove_size -gt 1024 ]]; then
    remove_size_h="$(echo "scale=1; $remove_size / 1024" | bc)K"
  else
    remove_size_h="${remove_size}B"
  fi

  echo "Will remove $remove_count session(s) ($remove_size_h)"

  # Confirm unless --yes
  if [[ "$yes" != "1" ]]; then
    read -rp "Proceed? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      return 0
    fi
  fi

  # Remove sessions
  for dir in "${to_remove[@]}"; do
    rm -rf "$dir"
  done

  echo "Removed $remove_count session(s) ($remove_size_h freed)."
}

sessions_clean_interactive() {
  local sessions_dir="$1"
  local current="$2"
  shift 2
  local sessions=("$@")

  local total=${#sessions[@]}
  local now=$(date +%s)

  # Calculate what each option would remove
  local d7_count=0 d7_size=0
  local d14_count=0 d14_size=0
  local d30_count=0 d30_size=0
  local all_count=0 all_size=0

  for entry in "${sessions[@]}"; do
    IFS='|' read -r mtime name dir <<< "$entry"
    [[ "$name" == "$current" ]] && continue

    local size_bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
    local age_days=$(( (now - mtime) / 86400 ))

    ((all_count++)) || true; all_size=$((all_size + size_bytes))
    [[ $age_days -ge 7 ]]  && { ((d7_count++));  d7_size=$((d7_size + size_bytes)); }
    [[ $age_days -ge 14 ]] && { ((d14_count++)); d14_size=$((d14_size + size_bytes)); }
    [[ $age_days -ge 30 ]] && { ((d30_count++)); d30_size=$((d30_size + size_bytes)); }
  done

  # Format sizes
  format_size() {
    local bytes=$1
    if [[ $bytes -gt 1048576 ]]; then
      echo "$(echo "scale=1; $bytes / 1048576" | bc)M"
    elif [[ $bytes -gt 1024 ]]; then
      echo "$(echo "scale=1; $bytes / 1024" | bc)K"
    else
      echo "${bytes}B"
    fi
  }

  echo "Remove sessions older than:"
  echo "  [1] 7 days   ($d7_count session(s), $(format_size $d7_size))"
  echo "  [2] 14 days  ($d14_count session(s), $(format_size $d14_size))"
  echo "  [3] 30 days  ($d30_count session(s), $(format_size $d30_size))"
  echo "  [4] all      ($all_count session(s), $(format_size $all_size))"
  echo "  [5] cancel"
  echo ""

  local choice
  read -rp "Choice [1-5]: " choice

  case "$choice" in
    1) sessions_clean "$sessions_dir" "7" "" "0" "1" ;;
    2) sessions_clean "$sessions_dir" "14" "" "0" "1" ;;
    3) sessions_clean "$sessions_dir" "30" "" "0" "1" ;;
    4) sessions_clean "$sessions_dir" "" "" "1" "1" ;;
    5) echo "Cancelled."; return 0 ;;
    *) echo "Invalid choice."; return 1 ;;
  esac
}

# ── Parse Arguments ───────────────────────────────────────────
CLAUDE_ARGS=()
EXEC_CMD=()
DRY_RUN=0
YOLO=0
SKIP_GIT_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)   PROFILE="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --config)    CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --yolo)      YOLO=1; shift ;;
    --skip-git-check) SKIP_GIT_CHECK=1; shift ;;
    --shell)     EXEC_CMD=("bash"); break ;;
    --exec)      shift; EXEC_CMD=("$@"); break ;;
    -h|--help)   usage ;;
    sessions)    shift; sessions_cmd "$@"; exit $? ;;
    --)          shift; CLAUDE_ARGS=("$@"); break ;;
    *)           CLAUDE_ARGS+=("$1"); shift ;;
  esac
done

# Apply default YOLO if not set via CLI flag
if [[ "$YOLO" == "0" && "$_CS_DEFAULT_YOLO" == "1" ]]; then
  YOLO=1
fi

# ── Pre-Session Git Check (Dev Profile Only) ──────────────────
check_git_status() {
  local cwd="$1"

  # Only for dev profile
  [[ "$PROFILE" != "dev" ]] && return 0

  # Skip if flag set
  [[ "$SKIP_GIT_CHECK" == "1" ]] && return 0

  # Skip if non-interactive (no tty on stdin)
  if [[ ! -t 0 ]]; then
    echo "Non-interactive mode: skipping git check" >&2
    return 0
  fi

  # Check if git is available
  if ! command -v git &>/dev/null; then
    return 0
  fi

  # Skip if not a git repo
  if ! git -C "$cwd" rev-parse --git-dir &>/dev/null 2>&1; then
    return 0
  fi

  # Check for changes
  local status
  status=$(git -C "$cwd" status --porcelain 2>/dev/null)
  [[ -z "$status" ]] && return 0

  # Check for merge/rebase in progress
  local merge_in_progress=0
  if [[ -d "$cwd/.git/rebase-merge" ]] || [[ -d "$cwd/.git/rebase-apply" ]] || \
     [[ -f "$cwd/.git/MERGE_HEAD" ]]; then
    merge_in_progress=1
  fi

  # Check for detached HEAD
  local detached_head=0
  if ! git -C "$cwd" symbolic-ref -q HEAD &>/dev/null; then
    detached_head=1
  fi

  # Show warning and options
  echo ""
  echo "┌──────────────────────────────────────────────────────────────┐"
  echo "│  Uncommitted changes detected in $cwd"
  echo "│"
  git -C "$cwd" status --porcelain 2>/dev/null | head -10 | while read -r line; do
    printf "│     %s\n" "$line"
  done
  local total
  total=$(echo "$status" | wc -l)
  [[ $total -gt 10 ]] && echo "│     ... and $((total-10)) more"
  echo "│"

  if [[ "$merge_in_progress" == "1" ]]; then
    echo "│  NOTE: Merge/rebase in progress. Auto-commit disabled."
    echo "│"
    echo "│  [1] Pause - I'll resolve manually (then press Enter)"
    echo "│  [3] Continue without committing"
    echo "│  [4] Abort"
  elif [[ "$detached_head" == "1" ]]; then
    echo "│  NOTE: Detached HEAD. Auto-commit may be lost."
    echo "│"
    echo "│  [1] Pause - I'll commit manually (then press Enter)"
    echo "│  [2] Auto-commit: \"pre-claude-$(date +%Y%m%d-%H%M%S)\""
    echo "│  [3] Continue without committing"
    echo "│  [4] Abort"
  else
    echo "│  [1] Pause - I'll commit manually (then press Enter)"
    echo "│  [2] Auto-commit: \"pre-claude-$(date +%Y%m%d-%H%M%S)\""
    echo "│  [3] Continue without committing"
    echo "│  [4] Abort"
  fi
  echo "│"
  echo "└──────────────────────────────────────────────────────────────┘"

  local choice
  # 30s timeout - abort is the safe default (protects uncommitted work)
  if ! read -t 30 -rp "  Choice [1-4]: " choice; then
    echo ""
    echo "Timeout. Aborting (use --skip-git-check to bypass)."
    exit 1
  fi

  case "$choice" in
    1)
      echo "Paused. Commit your changes, then press Enter..."
      read -r
      # Re-check after user commits
      status=$(git -C "$cwd" status --porcelain 2>/dev/null)
      if [[ -n "$status" ]]; then
        echo "Still uncommitted changes. Continuing anyway."
      else
        echo "Clean. Continuing."
      fi
      ;;
    2)
      if [[ "$merge_in_progress" == "1" ]]; then
        echo "Auto-commit not available during merge/rebase."
        return 0
      fi
      echo ""
      echo "WARNING: This runs git hooks from the repository with your user privileges."
      read -rp "  Proceed? [y/N]: " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local commit_msg="pre-claude-$(date +%Y%m%d-%H%M%S)"
        if git -C "$cwd" add -A && git -C "$cwd" commit -m "$commit_msg"; then
          echo "Committed as '$commit_msg'. Continuing."
        else
          echo "Commit failed. Continuing without commit."
        fi
      else
        echo "Skipped. Continuing without commit."
      fi
      ;;
    3)
      echo "Continuing without commit."
      ;;
    4)
      echo "Aborted."
      exit 0
      ;;
    *)
      echo "Invalid choice. Aborting."
      exit 1
      ;;
  esac
}

# ── Setup Workspace and Session Directory ─────────────────────
mkdir -p "$WORKSPACE"

# Create per-session directory for logs and context
SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"

# SECURITY: Validate session ID format to prevent path traversal
if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "ERROR: Invalid session ID format: $SESSION_ID" >&2
  exit 1
fi

SESSION_DIR="$WORKSPACE/.sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR"

# Create/update 'current' symlink (note: race condition with concurrent sessions)
ln -sfn "$SESSION_ID" "$WORKSPACE/.sessions/current"

# Session-specific paths
AUDIT_LOG="$SESSION_DIR/proxy-audit.log"
PROXY_LOG="$SESSION_DIR/proxy.log"

# Sandbox context file (not per-session - deterministic from profile)
SANDBOX_CONTEXT_FILE="$WORKSPACE/.sandbox-context.md"

# Backward compatibility: symlink at old location for tools expecting it
ln -sf "$AUDIT_LOG" "$WORKSPACE/.proxy-audit.log" 2>/dev/null || true

# Record session start time for duration calculation
START_TIME=$(date +%s)
START_TIME_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Export session info for sub-scripts
export _CS_SESSION_ID="$SESSION_ID"
export _CS_SESSION_DIR="$SESSION_DIR"
export _CS_START_TIME="$START_TIME"

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
export _CS_SESSION_ID
export _CS_SESSION_DIR

# ── Run Pre-Session Git Check ─────────────────────────────────
# Only runs for dev profile when launching Claude Code (not --exec/--shell)
if [[ ${#EXEC_CMD[@]} -eq 0 ]]; then
  check_git_status "$(pwd)"
fi

# ── Generate Sandbox Context for Claude Code ─────────────────
# Creates a system prompt addendum so Claude Code understands it's running
# in a sandbox and can handle restrictions gracefully instead of getting
# confused by missing files or blocked network requests.
# Uses --append-system-prompt-file to inject without touching user files.
# SANDBOX_CONTEXT_FILE is set earlier in session directory setup.
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

## Git Operations

Git credentials are blocked for security. Git read operations (log, diff, status,
blame, show) work normally. Git write operations have restrictions:

- **git commit**: Fails with "Please tell me who you are" unless the user provides
  identity via GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL environment variables
- **git push (HTTPS)**: Will prompt for credentials; user must enter manually
- **git push (SSH)**: Not supported — SSH keys are blocked and SSH traffic cannot
  go through the HTTP proxy

If git operations fail, explain this to the user and suggest:
1. For commits: Ask user to provide GIT_AUTHOR_NAME/EMAIL env vars
2. For push: Ask user to push outside the sandbox, or enter HTTPS credentials manually

Do NOT suggest workarounds involving SSH keys or credential files.

Note: Git configuration (~/.gitconfig) is readable for normal operations, but
credential stores (~/.git-credentials, ~/.config/gh) are blocked. If your gitconfig
contains inline credentials in URLs, consider removing them before using the sandbox.

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
  # PROXY_LOG is set earlier in session directory setup.

  "$PROXY_BIN" \
    --port "$PROXY_PORT" \
    --audit-log "$AUDIT_LOG" \
    "${domain_args[@]}" >>"$PROXY_LOG" 2>&1 &
  PROXY_PID=$!

  # Wait for proxy to be ready (up to 5 seconds)
  # Uses TCP connection check instead of HTTP request to avoid polluting audit log
  local ready=0
  for _ in $(seq 1 50); do
    if (echo >/dev/tcp/127.0.0.1/"$PROXY_PORT") 2>/dev/null; then
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

# ── Format Duration ───────────────────────────────────────────
format_duration() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))

  if [[ $hours -gt 0 ]]; then
    printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
  elif [[ $minutes -gt 0 ]]; then
    printf "%dm %ds" "$minutes" "$secs"
  else
    printf "%ds" "$secs"
  fi
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  local end_time=$(date +%s)
  local duration=$((end_time - START_TIME))

  [[ -n "${PROXY_PID:-}" ]]  && kill "$PROXY_PID" 2>/dev/null || true
  [[ -n "${SOCAT_PID:-}" ]]  && kill "$SOCAT_PID" 2>/dev/null || true
  [[ -n "${SOCKET_DIR:-}" ]] && rm -rf "$SOCKET_DIR" 2>/dev/null || true
  wait 2>/dev/null || true

  # Generate session report and display summary
  if [[ -f "$AUDIT_LOG" ]]; then
    local report_json="$SESSION_DIR/session-report.json"
    local report_script="$SCRIPTS_DIR/generate-report.sh"

    # Generate JSON report if script is available
    if [[ -x "$report_script" ]] || [[ -f "$report_script" ]]; then
      bash "$report_script" "$AUDIT_LOG" "$report_json" "$duration" "$PROFILE" "$WORKSPACE" 2>/dev/null || true
    fi

    # Parse counts from audit log directly for terminal display
    local blocked_count allowed_count total_count
    blocked_count=$(grep -c "BLOCKED" "$AUDIT_LOG" 2>/dev/null | head -1 || true)
    allowed_count=$(grep -c "ALLOWED" "$AUDIT_LOG" 2>/dev/null | head -1 || true)
    blocked_count="${blocked_count:-0}"
    allowed_count="${allowed_count:-0}"
    total_count=$((allowed_count + blocked_count))

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Session Report ($SESSION_ID)"
    echo "  Duration: $(format_duration "$duration") | Profile: $PROFILE"
    echo ""
    echo "  Network Activity"
    echo "  ────────────────────────────────────────────────────────────"
    echo "  Total: $total_count requests | Allowed: $allowed_count | Blocked: $blocked_count"

    # Show top domains
    if [[ $total_count -gt 0 ]]; then
      echo ""
      echo "  Top domains:"
      # Extract domain from both text and JSON formats
      awk '
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/ && /ALLOWED/ {
          # Text format: timestamp result method host[:port]
          split($4, hp, ":")
          domains[hp[1]]++
        }
        /^\{.*"result":"ALLOWED"/ {
          # JSON format
          if (match($0, /"host":"([^"]+)"/, m)) {
            domains[m[1]]++
          }
        }
        END {
          n = 0
          for (d in domains) {
            count[n] = domains[d]
            name[n] = d
            n++
          }
          # Simple bubble sort (top 5 is enough)
          for (i = 0; i < n-1; i++) {
            for (j = i+1; j < n; j++) {
              if (count[j] > count[i]) {
                tmp = count[i]; count[i] = count[j]; count[j] = tmp
                tmp = name[i]; name[i] = name[j]; name[j] = tmp
              }
            }
          }
          for (i = 0; i < 5 && i < n; i++) {
            printf "    %-30s %d requests\n", name[i], count[i]
          }
        }
      ' "$AUDIT_LOG" 2>/dev/null || true
    fi

    # Check for suspicious patterns and display warnings
    if [[ -f "$report_json" ]]; then
      # Extract risk info from JSON report
      local risk_score risk_level
      risk_score=$(grep -o '"risk_score": *[0-9]*' "$report_json" 2>/dev/null | grep -o '[0-9]*' || echo "0")
      risk_level=$(grep -o '"risk_level": *"[^"]*"' "$report_json" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/' || echo "none")

      # Show suspicious patterns if any
      if [[ "$risk_score" -gt 0 ]]; then
        echo ""
        echo "  SUSPICIOUS PATTERNS"
        echo "  ────────────────────────────────────────────────────────────"

        # Parse and display suspicious items
        # Extract JSON array content between "suspicious": [ and ]
        sed -n '/"suspicious":/,/\]/p' "$report_json" 2>/dev/null | \
          grep -o '"type":"[^"]*"' | sed 's/"type":"//;s/"//' | while read -r ptype; do
            case "$ptype" in
              repeated_blocks) echo "  [HIGH] Repeated attempts to blocked domain" ;;
              high_block_rate) echo "  [MED]  Unusually high blocked request ratio" ;;
              direct_ip_access) echo "  [LOW]  Direct IP access detected" ;;
              port_scanning) echo "  [MED]  Multiple ports accessed on same IP" ;;
              high_volume) echo "  [INFO] Unusually active session" ;;
            esac
          done

        echo ""
        local risk_label
        case "$risk_level" in
          high)   risk_label="HIGH" ;;
          medium) risk_label="MEDIUM" ;;
          low)    risk_label="LOW" ;;
          *)      risk_label="NONE" ;;
        esac
        echo "  Risk Score: $risk_score/100 ($risk_label)"
      fi
    fi

    # Show blocked requests if any
    if [[ "$blocked_count" -gt 0 ]]; then
      echo ""
      echo "  Blocked requests (review these):"
      grep "BLOCKED" "$AUDIT_LOG" 2>/dev/null | tail -5 | sed 's/^/     /'
    fi

    echo ""
    echo "  Session files:"
    echo "    Report: $report_json"
    echo "    Audit:  $AUDIT_LOG"
    echo "═══════════════════════════════════════════════════════════════"
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
echo "│  Session:   $SESSION_ID"
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
  bash "$SCRIPTS_DIR/linux-sandbox.sh" "${CLAUDE_ARGS[@]}"
elif [[ "${CLAUDE_SANDBOX_IS_DARWIN:-0}" == "1" ]]; then
  bash "$SCRIPTS_DIR/macos-sandbox.sh" "${CLAUDE_ARGS[@]}"
else
  echo "ERROR: Unsupported platform. Set CLAUDE_SANDBOX_IS_LINUX=1 or CLAUDE_SANDBOX_IS_DARWIN=1." >&2
  exit 1
fi
# cleanup() runs via EXIT trap after sandbox exits
