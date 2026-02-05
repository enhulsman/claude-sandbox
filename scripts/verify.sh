#!/usr/bin/env bash
# verify.sh — Sandbox isolation verification tests
#
# Run INSIDE the sandbox to confirm isolation is working.
# Tests filesystem, network, and privilege boundaries.
#
# Usage:
#   claude-sandbox --profile nixos-admin -- -p "bash /path/to/verify.sh"
#   nix run .#verify            # standalone on HOST (no sandbox — baseline comparison)

set -euo pipefail

PASS=0
FAIL=0
WARN=0

result() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    PASS) ((PASS++)) || true; printf "  \033[32m✓\033[0m %s\n" "$name" ;;
    FAIL) ((FAIL++)) || true; printf "  \033[31m✗\033[0m %s" "$name"
                      [[ -n "$detail" ]] && printf " — %s" "$detail"
                      printf "\n" ;;
    WARN) ((WARN++)) || true; printf "  \033[33m⚠\033[0m %s" "$name"
                      [[ -n "$detail" ]] && printf " — %s" "$detail"
                      printf "\n" ;;
  esac
}

# ── Platform ──────────────────────────────────────────────────
PLATFORM="unknown"
if [[ "${CLAUDE_SANDBOX_IS_LINUX:-0}" == "1" ]]; then
  PLATFORM="linux"
elif [[ "${CLAUDE_SANDBOX_IS_DARWIN:-0}" == "1" ]]; then
  PLATFORM="darwin"
elif [[ "$(uname -s)" == "Linux" ]]; then
  PLATFORM="linux"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  PLATFORM="darwin"
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  Claude Sandbox Verification Suite"
echo "  Platform: $PLATFORM"
echo "  Date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "══════════════════════════════════════════════"
echo ""


# ══════════════════════════════════════════════════════════════
# Filesystem Tests
# ══════════════════════════════════════════════════════════════
echo "── Filesystem Isolation ──────────────────────"

# SSH keys
if cat "$HOME/.ssh/id_rsa" &>/dev/null || \
   cat "$HOME/.ssh/id_ed25519" &>/dev/null || \
   cat "$HOME/.ssh/config" &>/dev/null; then
  result FAIL "~/.ssh blocked" "can read SSH key files"
elif ls "$HOME/.ssh/" &>/dev/null | grep -q .; then
  result FAIL "~/.ssh blocked" "can list SSH directory contents"
else
  result PASS "~/.ssh blocked"
fi

# /etc/shadow
if cat /etc/shadow &>/dev/null; then
  result FAIL "/etc/shadow blocked" "can read /etc/shadow"
else
  result PASS "/etc/shadow blocked"
fi

# GPG keys
if [[ -r "$HOME/.gnupg/private-keys-v1.d" ]] &>/dev/null || \
   ls "$HOME/.gnupg/" &>/dev/null | grep -q .; then
  result FAIL "~/.gnupg blocked" "can access GPG directory"
else
  result PASS "~/.gnupg blocked"
fi

# AWS credentials
if cat "$HOME/.aws/credentials" &>/dev/null; then
  result FAIL "~/.aws blocked" "can read AWS credentials"
else
  result PASS "~/.aws blocked"
fi

# Workspace writable
WORKSPACE="${CLAUDE_SANDBOX_WORKSPACE:-${_CS_WORKSPACE:-$HOME/claude-workspace}}"
if mkdir -p "$WORKSPACE" &>/dev/null && \
   echo "verify-test-$$" > "$WORKSPACE/.verify-test" &>/dev/null; then
  rm -f "$WORKSPACE/.verify-test"
  result PASS "Workspace writable ($WORKSPACE)"
else
  result FAIL "Workspace writable" "cannot write to $WORKSPACE"
fi

# System paths read-only (Linux only — on macOS, Seatbelt handles this)
if [[ "$PLATFORM" == "linux" ]]; then
  if touch /etc/.sandbox-write-test &>/dev/null; then
    rm -f /etc/.sandbox-write-test
    result FAIL "/etc read-only" "can write to /etc"
  else
    result PASS "/etc read-only"
  fi

  if touch /usr/.sandbox-write-test &>/dev/null; then
    rm -f /usr/.sandbox-write-test
    result FAIL "/usr read-only" "can write to /usr"
  else
    result PASS "/usr read-only"
  fi
fi

# Home directory write protection (outside workspace)
TESTFILE="$HOME/.sandbox-write-test-$$"
if echo "test" > "$TESTFILE" &>/dev/null; then
  rm -f "$TESTFILE"
  result WARN "Home dir write-protected" "can write to \$HOME (may be expected for 'dev' profile)"
else
  result PASS "Home dir write-protected"
fi

echo ""


# ══════════════════════════════════════════════════════════════
# Blocked Path Isolation Tests
# ══════════════════════════════════════════════════════════════
echo "── Blocked Path Isolation ────────────────────"

# NOTE: These tests verify that blocked paths (like ~/.ssh) are properly
# isolated inside the sandbox by bubblewrap's tmpfs mounts. They confirm
# that no sensitive content is accessible, regardless of how you try to
# reach it (direct access, symlinks, path traversal).
#
# IMPORTANT: These tests do NOT validate the pre-mount symlink resolution
# security fix. That validation happens BEFORE the sandbox starts and must
# be tested OUTSIDE the sandbox. See test-symlink-setup.sh for those tests.

# Test 1: Blocked path is empty (direct access)
if ls "$HOME/.ssh"/id_* 2>/dev/null | grep -q . || \
   ls "$HOME/.ssh"/*.pub 2>/dev/null | grep -q . || \
   cat "$HOME/.ssh/config" 2>/dev/null | grep -q .; then
  result FAIL "~/.ssh is empty" "blocked path contains files"
else
  result PASS "~/.ssh is empty (tmpfs isolation working)"
fi

# Test 2: Symlink to blocked path reaches empty tmpfs
TEST_LINK="/tmp/test-symlink-ssh-$$"
if ln -s "$HOME/.ssh" "$TEST_LINK" 2>/dev/null; then
  if ls "$TEST_LINK"/id_* 2>/dev/null | grep -q .; then
    result FAIL "Symlink reaches empty tmpfs" "symlink exposes SSH keys"
  else
    result PASS "Symlink reaches empty tmpfs"
  fi
  rm -f "$TEST_LINK"
else
  result WARN "Symlink reaches empty tmpfs" "cannot create test symlink"
fi

# Test 3: Path traversal reaches empty tmpfs
if ls "$HOME/../$(whoami)/.ssh"/id_* 2>/dev/null | grep -q .; then
  result FAIL "Path traversal blocked" "traversal exposes SSH keys"
else
  result PASS "Path traversal reaches empty tmpfs"
fi

# Test 4: Multi-hop symlink chain reaches empty tmpfs
LINK_A="/tmp/test-link-a-$$"
LINK_B="/tmp/test-link-b-$$"
if ln -s "$HOME/.ssh" "$LINK_A" 2>/dev/null && ln -s "$LINK_A" "$LINK_B" 2>/dev/null; then
  if ls "$LINK_B"/id_* 2>/dev/null | grep -q .; then
    result FAIL "Multi-hop chain blocked" "chain exposes SSH keys"
  else
    result PASS "Multi-hop symlink chain reaches empty tmpfs"
  fi
  rm -f "$LINK_A" "$LINK_B"
else
  result WARN "Multi-hop chain blocked" "cannot create test symlinks"
fi

echo ""

# ══════════════════════════════════════════════════════════════
# Path Handling Robustness Tests
# ══════════════════════════════════════════════════════════════
echo "── Path Handling Robustness ──────────────────"

# Test 5: Circular symlink (should not hang)
CIRC_A="/tmp/circ-a-$$"
CIRC_B="/tmp/circ-b-$$"
ln -s "$CIRC_B" "$CIRC_A" 2>/dev/null
ln -s "$CIRC_A" "$CIRC_B" 2>/dev/null
if timeout 2s ls -la "$CIRC_A" >/dev/null 2>&1; then
  result PASS "Circular symlink handled gracefully"
elif [[ $? -eq 124 ]]; then
  result FAIL "Circular symlink handling" "hung on circular symlink"
else
  result PASS "Circular symlink handled gracefully"
fi
rm -f "$CIRC_A" "$CIRC_B"

# Test 6: Broken symlink
BROKEN="/tmp/broken-link-$$"
ln -s "/nonexistent/path/that/does/not/exist" "$BROKEN" 2>/dev/null
if [[ -e "$BROKEN" ]]; then
  result FAIL "Broken symlink" "broken symlink appears to exist"
else
  result PASS "Broken symlink correctly non-existent"
fi
rm -f "$BROKEN"

# Test 7: Path with spaces
TEST_SPACE="/tmp/test path with spaces $$"
mkdir -p "$TEST_SPACE" 2>/dev/null
if [[ -d "$TEST_SPACE" ]]; then
  result PASS "Path with spaces handled correctly"
  rm -rf "$TEST_SPACE"
else
  result FAIL "Path with spaces" "path with spaces failed"
fi

# Test 8: CWD is in allowed location
ACTUAL_CWD="$(pwd -P)"
WORKSPACE="${CLAUDE_SANDBOX_WORKSPACE:-$HOME/claude-workspace}"
# CWD should be either in workspace or in a writable path
if [[ "$ACTUAL_CWD" == "$WORKSPACE"* ]] || [[ -w "$ACTUAL_CWD" ]]; then
  result PASS "CWD is in allowed writable location"
else
  result WARN "CWD location" "CWD=$ACTUAL_CWD may not be in expected location"
fi

echo ""


# ══════════════════════════════════════════════════════════════
# Network Tests
# ══════════════════════════════════════════════════════════════
echo "── Network Isolation ─────────────────────────"

# Direct ping (Linux only — tests --unshare-net)
if [[ "$PLATFORM" == "linux" ]]; then
  if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    result FAIL "Direct ping blocked" "ping 8.8.8.8 succeeded (network namespace may be missing)"
  else
    result PASS "Direct ping blocked (--unshare-net working)"
  fi
fi

# Curl to non-allowed domain via proxy
if curl -sf --connect-timeout 3 --max-time 5 \
     --proxy "${HTTP_PROXY:-${HTTPS_PROXY:-}}" \
     https://example.com &>/dev/null; then
  result FAIL "Non-allowed domain blocked" "curl to example.com succeeded"
elif curl -sf --connect-timeout 3 --max-time 5 \
     https://example.com &>/dev/null; then
  result FAIL "Non-allowed domain blocked" "direct curl to example.com succeeded (no proxy?)"
else
  result PASS "Non-allowed domain blocked"
fi

# Curl to allowed domain (api.anthropic.com)
# This may fail without a valid API key, but a TCP connection should succeed.
# We test with --head and accept any HTTP response as success.
if curl -sI --connect-timeout 5 --max-time 10 \
     --proxy "${HTTP_PROXY:-${HTTPS_PROXY:-}}" \
     https://api.anthropic.com/ &>/dev/null; then
  result PASS "Allowed domain reachable (api.anthropic.com)"
else
  # Could be proxy not running or network issue — warn, don't fail
  result WARN "Allowed domain reachable" "api.anthropic.com unreachable (proxy running?)"
fi

# DNS resolution of arbitrary domain
if [[ "$PLATFORM" == "linux" ]]; then
  if nslookup evil.example.com &>/dev/null || \
     host evil.example.com &>/dev/null || \
     dig evil.example.com &>/dev/null; then
    result FAIL "DNS exfiltration blocked" "DNS lookup succeeded"
  else
    result PASS "DNS exfiltration blocked"
  fi
else
  result WARN "DNS isolation" "macOS Seatbelt does not fully isolate DNS; proxy handles filtering"
fi

# Direct TCP connection to arbitrary port (Linux)
if [[ "$PLATFORM" == "linux" ]]; then
  if (echo "test" > /dev/tcp/93.184.216.34/80) 2>/dev/null; then
    result FAIL "Direct TCP blocked" "raw TCP connection succeeded"
  else
    result PASS "Direct TCP blocked"
  fi
fi

echo ""


# ══════════════════════════════════════════════════════════════
# Privilege Tests
# ══════════════════════════════════════════════════════════════
echo "── Privilege Isolation ────────────────────────"

# sudo
if sudo -n true 2>/dev/null; then
  result FAIL "sudo blocked" "sudo works without password"
else
  result PASS "sudo blocked"
fi

# Remount (Linux)
if [[ "$PLATFORM" == "linux" ]]; then
  if mount -o remount,rw / 2>/dev/null; then
    result FAIL "Remount blocked" "could remount / as read-write"
  else
    result PASS "Remount blocked"
  fi
fi

# Creating users
if useradd testuser-$$ 2>/dev/null; then
  userdel testuser-$$ 2>/dev/null || true
  result FAIL "User creation blocked" "could create a user"
else
  result PASS "User creation blocked"
fi

echo ""


# ══════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════"
echo "  Results"
printf "  Passed:   \033[32m%d\033[0m\n" "$PASS"
printf "  Failed:   \033[31m%d\033[0m\n" "$FAIL"
printf "  Warnings: \033[33m%d\033[0m\n" "$WARN"
echo "══════════════════════════════════════════════"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  printf "\033[31m⚠ SANDBOX HAS GAPS — review failed tests before using Claude Code\033[0m\n"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  printf "\033[33m⚠ Sandbox operational with warnings. Review above.\033[0m\n"
  exit 0
else
  printf "\033[32m✓ All tests passed. Sandbox isolation verified.\033[0m\n"
  exit 0
fi
