# Claude Code Hooks for claude-sandbox

This directory contains optional hooks that can be installed into Claude Code to add extra layers of protection when using the sandbox.

## pretooluse-guard.sh

A PreToolUse hook that detects potentially harmful commands before they are executed. It checks for patterns like:

| Category | Examples | Severity |
|----------|----------|----------|
| Sandbox escape | `bwrap`, `unshare`, `nsenter`, `firejail` | CRITICAL |
| Network bypass | `socat TCP:`, `nc -l`, direct IP URLs | HIGH |
| Credential access | `security find-*-password`, `gpg --export-secret` | HIGH |
| Privilege escalation | `sudo`, `su -`, `pkexec`, `doas` | HIGH |
| System damage | `rm -rf /`, `mkfs`, `dd of=/dev/` | HIGH |
| Persistence | `crontab`, `systemctl enable`, `launchctl load` | MEDIUM |
| Data exfiltration | `base64 | curl`, `cat | wget --post` | MEDIUM |
| Shell injection | `eval $var`, backtick with curl | MEDIUM |

### Installation

1. Copy the hook to your Claude Code hooks directory:

```bash
mkdir -p ~/.claude/hooks
cp hooks/pretooluse-guard.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/pretooluse-guard.sh
```

2. Configure Claude Code to use it. Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "~/.claude/hooks/pretooluse-guard.sh"}]
    }]
  }
}
```

3. Restart Claude Code for the changes to take effect.

### Testing

Verify the hook is working:

```bash
# This should be blocked
echo '{"tool_name":"Bash","tool_input":{"command":"sudo ls"}}' | ~/.claude/hooks/pretooluse-guard.sh

# This should pass (exit silently)
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | ~/.claude/hooks/pretooluse-guard.sh
```

## CRITICAL SECURITY WARNING

**This hook is a "speed bump", NOT a security boundary.**

The hook can be trivially bypassed. Here are just a few examples:

### Variable expansion
```bash
# Hook sees: $s ls
# Executed: sudo ls
s="sudo"; $s ls
```

### Base64 encoding
```bash
# Hook sees: echo ... | base64 -d | bash
# Executed: sudo ls
echo c3VkbyBscw== | base64 -d | bash
```

### Hex/octal escapes
```bash
# Hook sees: $'\x73\x75...'
# Executed: sudo
$'\x73\x75\x64\x6f' ls
```

### Indirect execution
```bash
# Hook sees: bash -c "..."
# The inner command is just a string literal
bash -c "sudo ls"
```

### Command construction
```bash
# Hook sees: cmd=...; $cmd
cmd="su"; ${cmd}do ls
```

**The sandbox itself is the real security boundary.** This hook exists to:

1. **Catch obvious mistakes** - Accidental `sudo` or `rm -rf /` typos
2. **Alert users to suspicious patterns** - When Claude suggests something risky
3. **Add friction to prompt injection** - Makes attacks slightly harder

If you rely on this hook for security, you will be disappointed. Always ensure the actual sandbox (bubblewrap/Seatbelt) is properly configured and active.

### What the hook CANNOT prevent

Even if the hook blocks a command, a determined attacker or prompt injection could:

- Use any of the bypass techniques above
- Write a script to disk and execute it
- Use language-specific methods (`os.system()` in Python, etc.)
- Encode malicious commands in files Claude writes

### What the sandbox DOES prevent

The sandbox provides actual isolation:

- **Filesystem**: Blocked paths are literally invisible (bind-mounted to /dev/null)
- **Network**: All traffic must go through the proxy (kernel-level on Linux)
- **Capabilities**: No privilege escalation possible (unprivileged user namespace)

The hook is defense-in-depth, but the sandbox is defense-in-actuality.

## Customization

Feel free to modify `pretooluse-guard.sh` to:

- Add patterns specific to your environment
- Remove patterns that cause false positives
- Adjust severity levels
- Add logging/alerting

The hook receives JSON on stdin with this structure:
```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "the command to execute"
  }
}
```

To deny a command, output:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Your reason here"
  }
}
```

To allow a command, exit with code 0 and produce no output.
