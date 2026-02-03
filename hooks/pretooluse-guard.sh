#!/usr/bin/env bash
# pretooluse-guard.sh — PreToolUse hook for claude-sandbox
#
# Detects potentially harmful commands before execution. This is a "speed bump"
# to catch obvious/accidental dangerous commands, NOT a security boundary.
#
# CRITICAL SECURITY NOTE:
# This hook can be trivially bypassed via variable expansion, base64, hex escapes,
# or indirect execution. The sandbox itself is the real security boundary.
# See hooks/README.md for details and bypass examples.
#
# Installation:
#   mkdir -p ~/.claude/hooks
#   cp hooks/pretooluse-guard.sh ~/.claude/hooks/
#   chmod +x ~/.claude/hooks/pretooluse-guard.sh
#
# Configure in ~/.claude/settings.json:
#   {
#     "hooks": {
#       "PreToolUse": [{
#         "matcher": "Bash",
#         "hooks": [{"type": "command", "command": "~/.claude/hooks/pretooluse-guard.sh"}]
#       }]
#     }
#   }

set -euo pipefail

# Read JSON input from stdin
INPUT=$(cat)

# Extract tool name and command
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# Only process Bash tool calls
[[ "$TOOL_NAME" != "Bash" ]] && exit 0
[[ -z "$COMMAND" ]] && exit 0

# Helper function to deny a command with a reason
deny() {
  local reason="$1"
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[claude-sandbox] $reason"
  }
}
EOF
  exit 0
}

# ═══════════════════════════════════════════════════════════════
# Pattern Detection
# ═══════════════════════════════════════════════════════════════

# --- CRITICAL: Sandbox escape attempts ---
if echo "$COMMAND" | grep -qE '\b(bwrap|bubblewrap|sandbox-exec|unshare|nsenter|firejail|chroot|pivot_root)\b'; then
  deny "Blocked: sandbox manipulation tool detected"
fi

# --- HIGH: Network bypass attempts ---
# Direct socket connections that bypass the proxy
if echo "$COMMAND" | grep -qE 'socat.*TCP:|socat.*UDP:'; then
  deny "Blocked: direct socket connection (bypasses proxy)"
fi

# Netcat variants (excluding help flags)
if echo "$COMMAND" | grep -qE '\bnc\s+-[^h]|\bncat\b|\bnetcat\b'; then
  deny "Blocked: netcat connection attempt (bypasses proxy)"
fi

# Direct IP connections (curl/wget to numeric IPs bypass domain filtering)
if echo "$COMMAND" | grep -qE '(curl|wget|fetch).*\s+["\x27]?https?://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
  deny "Blocked: direct IP connection (bypasses domain allowlist)"
fi

# --- HIGH: Credential access ---
# macOS Keychain
if echo "$COMMAND" | grep -qE 'security\s+find-(generic|internet)-password'; then
  deny "Blocked: macOS keychain access attempt"
fi

# GPG secret key export
if echo "$COMMAND" | grep -qE 'gpg.*--export-secret'; then
  deny "Blocked: GPG secret key export attempt"
fi

# SSH key operations
if echo "$COMMAND" | grep -qE 'ssh-add\s+-[dDxXeEsStTLl]|ssh-keygen.*-[pe]'; then
  deny "Blocked: SSH key manipulation attempt"
fi

# --- HIGH: Privilege escalation ---
if echo "$COMMAND" | grep -qE '\b(sudo|pkexec|doas)\b'; then
  deny "Blocked: privilege escalation attempt (sudo/pkexec/doas)"
fi

if echo "$COMMAND" | grep -qE '\bsu\s+-|\bsu\s+root\b|\bsu\s*$'; then
  deny "Blocked: privilege escalation attempt (su)"
fi

# --- HIGH: System damage ---
# Recursive delete from root or important directories
if echo "$COMMAND" | grep -qE 'rm\s+(-[rfRvI]*\s+)*(-[rfRvI]*)?/($|\s|;|&|\|)|rm\s+(-[rfRvI]*\s+)*/etc|rm\s+(-[rfRvI]*\s+)*/var|rm\s+(-[rfRvI]*\s+)*/usr'; then
  deny "Blocked: dangerous recursive delete"
fi

# Disk formatting
if echo "$COMMAND" | grep -qE '\bmkfs\b|dd\s+.*of=/dev/'; then
  deny "Blocked: disk formatting/overwriting command"
fi

# Dangerous chmod on system dirs
if echo "$COMMAND" | grep -qE 'chmod\s+(-[rwxR]*\s+)*777\s+/'; then
  deny "Blocked: dangerous permission change on root"
fi

# --- MEDIUM: Persistence mechanisms ---
if echo "$COMMAND" | grep -qE '\bcrontab\b'; then
  deny "Blocked: crontab modification (persistence mechanism)"
fi

if echo "$COMMAND" | grep -qE 'systemctl\s+(enable|mask|unmask)'; then
  deny "Blocked: systemd service persistence"
fi

if echo "$COMMAND" | grep -qE 'launchctl\s+(load|enable|bootstrap)'; then
  deny "Blocked: launchd service persistence"
fi

# --- MEDIUM: Data exfiltration patterns ---
# Piping sensitive data to curl/wget POST
if echo "$COMMAND" | grep -qE '(cat|head|tail|base64).*\|.*(curl|wget).*(-d|--data|--post)'; then
  deny "Blocked: potential data exfiltration via POST"
fi

# Base64 encoding piped to network tools
if echo "$COMMAND" | grep -qE 'base64.*\|.*(curl|wget|nc|ncat)'; then
  deny "Blocked: encoded data exfiltration attempt"
fi

# DNS exfiltration via dig/nslookup
if echo "$COMMAND" | grep -qE '(dig|nslookup|host)\s+.*\$'; then
  deny "Blocked: potential DNS exfiltration"
fi

# --- MEDIUM: Shell injection patterns ---
# Eval with variable expansion (common injection vector)
if echo "$COMMAND" | grep -qE 'eval\s+.*\$'; then
  deny "Blocked: eval with variable expansion (injection risk)"
fi

# Backtick command substitution with network tools
if echo "$COMMAND" | grep -qE '`.*curl.*`|`.*wget.*`'; then
  deny "Blocked: command substitution with network tool"
fi

# --- LOW: Environment manipulation ---
# LD_PRELOAD injection
if echo "$COMMAND" | grep -qE 'LD_PRELOAD=|LD_LIBRARY_PATH=.*:'; then
  deny "Blocked: dynamic linker manipulation"
fi

# ═══════════════════════════════════════════════════════════════
# If we reach here, allow the command
# ═══════════════════════════════════════════════════════════════
exit 0
