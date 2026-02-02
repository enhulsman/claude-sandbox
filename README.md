# Claude Sandbox

A cross-platform, defense-in-depth sandbox for running Claude Code safely on
**NixOS**, **Raspberry Pi**, **Ubuntu**, and **macOS** — from a single portable
configuration.

```
nix run github:enhulsman/claude-sandbox -- --profile dev -- -p "review this code"
```

---

## What This Does

Claude Code is powerful: it reads your files, runs commands, and modifies your
codebase. That power creates risk — prompt injection can trick it into
exfiltrating secrets, and approval fatigue means you might not notice. This
project wraps Claude Code in an **external** sandbox that enforces:

1. **Filesystem isolation** — Claude can only read/write paths you explicitly allow
2. **Network isolation** — all traffic goes through a filtering proxy; only allowed domains pass
3. **Audit logging** — every network request is logged so you can review after each session

It uses OS-native sandboxing (bubblewrap on Linux, Seatbelt on macOS) for
kernel-level enforcement, not just permissions. A Nix flake handles all
dependencies and platform detection automatically.


## Why an External Sandbox

Claude Code has built-in sandboxing (`/sandbox` command). Why wrap it again?

Because **a bug in Claude Code's sandbox disables Claude Code's sandbox.**
This has happened — CVE-2025-54794 and CVE-2025-54795 both involved sandbox
bypasses in AI coding agents. Patrick McCanna's key insight: if the application
contains its own sandbox, a vulnerability in the application can disable it.
An external wrapper provides defense-in-depth: even if Claude Code's internal
sandbox fails, the outer sandbox still holds.


---

## Quick Start

### Prerequisites

All you need is the Nix package manager. It runs on every target platform and includes Claude Code automatically.

```bash
# Install Nix (one-time, ~2 minutes, works on Linux and macOS)
curl -sSf -L https://install.determinate.systems/nix | sh -s -- install

# Restart your shell, then verify:
nix --version
```

The first run will download Claude Code (~180MB native binary) and sandbox components. Subsequent runs start instantly from cache.

**Authentication**: Before your first session, you need Claude Code credentials:

```bash
# Start Claude Code to authenticate (bundled with sandbox)
nix run github:enhulsman/claude-sandbox#claude-code

# Follow the login prompts, then exit
```

This creates `~/.claude/.credentials.json` and `~/.claude.json`, which are automatically mounted into the sandbox.

### Run It

```bash
# Clone (or point to your GitHub URL directly)
git clone https://github.com/enhulsman/claude-sandbox.git
cd claude-sandbox

# Run sandboxed Claude Code with the 'dev' profile (interactive)
nix run . -- --profile dev

# Run with a one-shot prompt
nix run . -- --profile dev -- -p "help me refactor this function"

# Or run directly from GitHub (no clone needed)
nix run github:enhulsman/claude-sandbox -- --profile dev -- -p "hello"
```

### Per-Platform Examples

**NixOS desktop:**
```bash
nix run . -- --profile nixos-admin -- -p "Bluetooth pairs but no audio. Diagnose."
```

**Raspberry Pi (aarch64, Debian):**
```bash
# First run downloads deps (~100MB). Subsequent runs are instant.
nix run . -- --profile dev -- -p "optimize this Python script for Pi"
```

**Ubuntu VPS:**
```bash
nix run . -- --profile strict -- -p "audit this repo for vulnerabilities"
```

**macOS (Apple Silicon or Intel):**
```bash
nix run . -- --profile macos-admin -- -p "why is launchd using so much CPU"
```

### Shell Aliases

Add to `~/.bashrc` or `~/.zshrc`:

```bash
alias claude-safe='nix run /path/to/claude-sandbox --'
alias claude-admin='nix run /path/to/claude-sandbox -- --profile nixos-admin --'
alias claude-dev='nix run /path/to/claude-sandbox -- --profile dev --'
alias claude-strict='nix run /path/to/claude-sandbox -- --profile strict --'
```

### Updating Claude Code

Claude Code is bundled via [claude-code-nix](https://github.com/sadjow/claude-code-nix) (updated hourly). To get the latest version:

```bash
# Update all flake inputs
nix flake update

# Or run directly from GitHub (always latest)
nix run github:enhulsman/claude-sandbox -- --profile dev
```

To pin to a specific version, edit `flake.nix`:
```nix
claude-code-nix.url = "github:sadjow/claude-code-nix?ref=v2.0.76";
```


---

## Profiles

Profiles define what Claude can see, where it can write, and which network
domains it can reach. Select one with `--profile NAME`.

| Profile | Filesystem Reads | Writes To | Network |
|---------|-----------------|-----------|---------|
| **dev** | Project dir + system libs | `.` (cwd) + workspace | Anthropic API + package registries |
| **nixos-admin** | `/etc/nixos`, `/var/log`, `/nix`, `/run/current-system` | Workspace only | Anthropic API only |
| **macos-admin** | `/Library`, `/opt/homebrew`, `/private/var/log` | Workspace only | Anthropic API only |
| **strict** | Minimal system libs only | Workspace only | Anthropic API only |

All profiles **block**: `~/.ssh`, `~/.gnupg`, `~/.aws`, `/etc/shadow`,
browser profiles, keyrings, and other credential stores.

All profiles always include `~/claude-workspace` as a writable directory.
`platform.claude.com` is always included in allowed domains (required for
authentication).

### Custom Profiles

Edit `config.toml` to add your own:

```toml
[profile.my-project]
description = "My specific project"

[profile.my-project.filesystem]
read_only = [
    "/nix",
    "~/projects/my-project",
]
blocked = [
    "~/.ssh",
    "~/.gnupg",
]
writable = [
    "~/projects/my-project/src",
]

[profile.my-project.network]
allowed_domains = [
    "api.anthropic.com",
    "registry.npmjs.org",
]
```

### Per-Host Configuration

Override the config file:

```bash
export CLAUDE_SANDBOX_CONFIG=~/.config/claude-sandbox/config.toml
claude-sandbox --profile nixos-admin -- -p "check system health"
```


---

## Human Workflow

The sandbox handles technical isolation. This section handles **you** — because
approval fatigue and social engineering are the most likely ways something goes
wrong in practice.

### The Golden Rule

> **Claude proposes → You review → You apply.**

Claude never has write access to system configuration. It writes proposals to
the workspace. You review them. You apply them with sudo.

### Before Each Session

- [ ] **Choose the right profile.** System admin → `nixos-admin`/`macos-admin`.
      Development → `dev`. Untrusted code → `strict`.
- [ ] **Commit your work.** `git add -A && git commit -m "before claude"` so you
      can revert if needed.
- [ ] **Clean the workspace.** `rm -rf ~/claude-workspace/*` — previous session
      artifacts should not contaminate new sessions.
- [ ] **Verify the sandbox** (first time or after updates):
      `nix run . -- --profile dev --exec bash scripts/verify.sh`

### During the Session

**Actually read what Claude is doing.** The sandbox limits blast radius, but it
doesn't prevent Claude from proposing bad changes. You are the last line of
defense.

Watch for these red flags:

| Red Flag | Why It's Suspicious |
|----------|-------------------|
| Claude suggests installing `curl`, `wget`, `nc` | Why does it need to download something? |
| Commands with base64 encoding/decoding | Data obfuscation — hiding what's being sent/received |
| Accessing `~/.bashrc`, `~/.zshrc`, dotfiles | Why is a NixOS task touching shell config? |
| "Temporarily disable the sandbox" | No. Never. |
| Unusually insistent about a specific command | Prompt injection often manifests as urgency |
| Long commands with complex pipes, `&&`, backticks | Malicious payload may be pushed off-screen |
| References to non-allowlisted domains | Exfiltration attempt |

If something seems wrong: **end the session, start fresh, review the audit log.**

### After the Session

The launcher prints a session summary automatically on exit, showing how many
requests were allowed/blocked and listing any blocked requests for review.

For deeper review:

```bash
# Full audit log — every request with timestamp and status
cat ~/claude-workspace/.proxy-audit.log

# What domains were contacted?
awk '{print $4}' ~/claude-workspace/.proxy-audit.log | sort -u

# Were any requests blocked? (potential prompt injection indicators)
grep BLOCKED ~/claude-workspace/.proxy-audit.log

# Were any unexpected domains ALLOWED?
grep ALLOWED ~/claude-workspace/.proxy-audit.log | grep -v anthropic

# Proxy startup messages and errors (separate from audit)
cat ~/claude-workspace/.proxy.log

# Review Claude's proposals before applying
ls ~/claude-workspace/
diff /etc/nixos/configuration.nix ~/claude-workspace/proposed-configuration.nix
```

### Applying Changes (NixOS Example)

```bash
# 1. Review the diff
diff /etc/nixos/configuration.nix ~/claude-workspace/proposed-configuration.nix

# 2. Copy the file (you do this, not Claude)
sudo cp ~/claude-workspace/proposed-configuration.nix /etc/nixos/configuration.nix

# 3. Dry run first — always
sudo nixos-rebuild dry-run

# 4. If the dry run looks right, apply
sudo nixos-rebuild switch

# 5. If something breaks, revert
sudo git -C /etc/nixos checkout .
sudo nixos-rebuild switch
```

### Things You Should Never Do

| Don't | Why |
|-------|-----|
| Copy-paste error messages from untrusted websites into Claude | May contain hidden prompt injection (invisible Unicode, white-on-white text) |
| Run `--dangerously-skip-permissions` without the external sandbox | Removes all protection |
| Add `*` or broad wildcards to domain allowlist | Defeats network isolation |
| Use the same session for trusted and untrusted repos | Context pollution — reading a poisoned file can influence later behavior |
| Auto-approve commands without reading them | Approval fatigue is the #1 real-world risk |
| Give Claude sudo access | Amplifies every mistake |
| Skip the dry-run step | Unreviewed changes to a live system |


---

## How It Works

### Architecture

```
 ┌──────────────────────────────────────────────────────────────┐
 │                    UNIFIED CONFIG (config.toml)              │
 │  Profiles: nixos-admin, dev, strict, macos-admin, custom     │
 └──────────────┬───────────────────────┬───────────────────────┘
                │                       │
     ┌──────────▼─────────┐  ┌──────────▼─────────┐
     │   LINUX             │  │   macOS              │
     │   bubblewrap        │  │   sandbox-exec       │
     │   --unshare-net     │  │   Seatbelt .sb       │
     │   socat bridge      │  │   localhost proxy     │
     └──────────┬─────────┘  └──────────┬─────────┘
                │                       │
     ┌──────────▼───────────────────────▼──────────┐
     │     EGRESS PROXY (Python, identical both)    │
     │     Domain allowlist + audit logging          │
     │     HTTP CONNECT + SOCKS5                     │
     └──────────────────────────────────────────────┘
```

### Linux (NixOS, Ubuntu, Raspberry Pi)

1. **bubblewrap** creates new mount and network namespaces
2. `--unshare-net` removes **all** network access — airtight, no bypass without kernel exploit
3. A **two-stage socat bridge** provides the only path out of the sandbox:
   - Host side: `socat UNIX-LISTEN:/tmp/proxy.sock → TCP:127.0.0.1:PROXY_PORT`
   - Sandbox side: `socat TCP-LISTEN:18080 → UNIX-CONNECT:/tmp/proxy.sock`
4. `HTTP_PROXY`/`ALL_PROXY` environment variables route Claude's traffic through the internal TCP port
5. The **egress proxy** checks every request against the domain allowlist

The two-stage bridge is needed because Claude Code's compiled Node.js binary
doesn't support Unix socket proxy URLs — it needs a TCP endpoint. The Unix
socket passes through bwrap's `--bind`, connecting the network-isolated sandbox
to the host-side proxy.

Network path:
```
Claude (sandbox) → TCP:18080 → socat → Unix socket → socat → TCP proxy → allowlist → internet
```

On **usr-merge systems** (Debian Bookworm, Raspberry Pi OS, Ubuntu 24+) where
`/bin`, `/lib`, `/sbin` are symlinks to `/usr/*`, the sandbox correctly
mounts `/usr` and recreates the symlinks inside bwrap rather than
following the symlinks (which would break the dynamic linker).

### macOS (Apple Silicon, Intel)

1. **sandbox-exec** applies a Seatbelt profile at the kernel level
2. The profile denies all network except `localhost:PROXY_PORT`
3. `HTTP_PROXY` routes Claude's traffic through `127.0.0.1:PROXY_PORT`
4. The **egress proxy** (same as Linux) checks every request

Network path:
```
Claude (Seatbelt) → HTTP_PROXY → 127.0.0.1:PORT → allowlist check → internet
                    ↓ direct connection attempt?
              Seatbelt blocks (not localhost)
```

### The Egress Proxy

The proxy is the security-critical portable component. Same Python on every OS.

- Listens on localhost for HTTP CONNECT (HTTPS) and plain HTTP requests
- Also speaks SOCKS5 for tools that ignore `HTTP_PROXY`
- Checks every destination hostname against the configured allowlist
- Logs every request (allowed or blocked) with timestamp to the audit file
- Returns HTTP 403 for blocked requests
- Proxy output (startup messages, errors) goes to `~/claude-workspace/.proxy.log`
- Audit log (ALLOWED/BLOCKED entries) goes to `~/claude-workspace/.proxy-audit.log`

### Seatbelt vs Bubblewrap

| | bubblewrap (Linux) | Seatbelt (macOS) |
|-|---|---|
| Network isolation | Complete (empty namespace) | Profile rules (deny + localhost exception) |
| Filesystem isolation | Bind mounts (precise) | LISP rules (order-dependent) |
| DNS isolation | ✓ (no network = no DNS) | ✗ (proxy handles domain filtering) |
| Escape difficulty | Kernel exploit required | SIP bypass or profile bug |
| Deprecation risk | None | sandbox-exec is undocumented/deprecated (still works) |


---

## Verification

Run the verification script to confirm isolation is working:

```bash
# Run inside the sandbox using --exec mode
nix run . -- --profile dev --exec bash scripts/verify.sh
```

Expected result: all tests pass (green ✓), with one warning for home directory
write access (expected — `~/.claude.json` needs to be writable for auth).

Tests include:
- `~/.ssh`, `~/.gnupg`, `~/.aws`, `/etc/shadow` are inaccessible
- Workspace is writable
- `/etc` and `/usr` are read-only
- Direct ping fails (Linux: `--unshare-net`)
- Non-allowed domains are blocked via proxy
- Allowed domains (api.anthropic.com) are reachable
- DNS exfiltration is blocked (Linux)
- Direct TCP connections are blocked (Linux)
- sudo, remount, and user creation are blocked

**Always verify after first setup and after any updates.**


---

## File Structure

```
claude-sandbox/
├── flake.nix                     # Nix flake: multi-platform packaging
├── flake.lock                    # Pinned dependency versions (auto-generated)
├── config.toml                   # Profile definitions
├── scripts/
│   ├── claude-sandbox.sh         # Main launcher: args, config, proxy, dispatch
│   ├── linux-sandbox.sh          # Linux: bubblewrap + two-stage socat bridge
│   ├── macos-sandbox.sh          # macOS: sandbox-exec + Seatbelt
│   ├── generate-seatbelt.sh      # Generates .sb profile from config
│   ├── egress-proxy.py           # Network proxy (Python, cross-platform)
│   └── verify.sh                 # Sandbox isolation tests
└── README.md                     # You are here
```


---

## Options Reference

```
claude-sandbox [OPTIONS] [-- CLAUDE_ARGS...]

Options:
  --profile PROFILE     Security profile (default: dev)
                        Built-in: dev, nixos-admin, macos-admin, strict
  --workspace DIR       Writable workspace (default: ~/claude-workspace)
  --config FILE         Path to config.toml (default: built-in)
  --exec CMD [ARGS]     Run CMD instead of Claude Code (for testing/debugging)
  --dry-run             Show what would be done without executing
  -h, --help            Show help

Examples:
  claude-sandbox --profile dev                                # interactive Claude Code
  claude-sandbox --profile dev -- -p "hello"                  # one-shot prompt
  claude-sandbox --profile dev --exec bash scripts/verify.sh  # run verify script
  claude-sandbox --profile dev --exec bash                    # interactive shell in sandbox
  claude-sandbox --profile dev --exec cat /etc/shadow         # test if file is blocked

Environment Variables:
  CLAUDE_SANDBOX_PROFILE    Default profile
  CLAUDE_SANDBOX_WORKSPACE  Default workspace directory
  CLAUDE_SANDBOX_CONFIG     Path to config.toml
```


---

## Troubleshooting

**"claude not found in PATH"**
This should not happen as Claude Code is bundled with the sandbox. If you see this error, please report it as a bug with your system details.

**"bwrap: No such file or directory" (Linux)**
The Nix flake should provide bubblewrap automatically. If running outside Nix:
`sudo apt install bubblewrap socat` (Debian/Ubuntu) or
`sudo pacman -S bubblewrap socat` (Arch).

**"sandbox-exec: command not found" (macOS)**
sandbox-exec is built into macOS. If you see this, something is wrong with your
PATH. Try: `/usr/bin/sandbox-exec --help`

**Claude Code prompts for login despite being authenticated**
The sandbox needs both `~/.claude/.credentials.json` (OAuth token) and
`~/.claude.json` (account binding). The latter is a separate file in your home
directory (not inside `~/.claude/`) that contains your `oauthAccount` with
`accountUuid` and `organizationUuid`. Make sure you've logged into Claude Code
at least once outside the sandbox. Both files are automatically mounted.

**Claude Code hangs at startup**
The proxy may not be starting. Check: `ss -tlnp | grep PROXY_PORT` (Linux) or
`lsof -i :PORT` (macOS). The proxy log at `~/claude-workspace/.proxy.log`
will show startup messages, and `~/claude-workspace/.proxy-audit.log`
will show if requests are reaching the proxy.

**"Connection refused" or "proxy error"**
Check that `api.anthropic.com` is in the profile's `allowed_domains`. The proxy
blocks everything not explicitly allowed.

**"Connection reset by peer" from socat during blocked requests**
This is normal. When the proxy blocks a domain, it closes the connection,
which socat reports as a connection reset. These messages go to the proxy log
file and don't affect Claude Code.

**`--exec` mode: "Try 'coreutils --help'" instead of running the command**
This happened with an earlier version where symlinks were resolved. The current
version preserves argv[0] for Nix multicall binaries (`cat`, `ls`, etc. are
symlinks to `coreutils`). Update to the latest version.

**Verification tests fail**
Run with `--dry-run` first to see what paths and domains are configured.
Paths that don't exist on your system are silently skipped.

**macOS: "operation not permitted" on legitimate files**
The Seatbelt profile may be too restrictive. Check
`/tmp/claude-sandbox-*.sb` for the generated profile. You may need to add
paths to your profile's `read_only` list in `config.toml`.

**Raspberry Pi: first run is slow**
Nix is downloading pre-built packages for aarch64-linux. Subsequent runs use
the local cache and start in under a second.


---

## Security Model

### What This Protects Against

| Threat | Protection |
|--------|-----------|
| Prompt injection → secret exfiltration | Blocked paths prevent reading; proxy blocks non-allowed domains |
| Prompt injection → reverse shell | Network namespace (Linux) or Seatbelt deny (macOS) blocks outbound |
| Prompt injection → arbitrary file write | Write restricted to workspace only |
| Approval fatigue | Sandbox auto-allows within boundaries; fewer prompts = less fatigue |
| Context pollution | Fresh sessions; workspace cleaned between runs |
| Claude Code sandbox bypass (CVE) | External sandbox is independent — still holds if internal fails |
| DNS exfiltration | Linux: no DNS (empty network namespace). macOS: proxy filters domains |
| Data exfiltration via encoding | Proxy logs all requests; review audit log for unexpected domains |

### What This Does NOT Protect Against

| Risk | Why | Mitigation |
|------|-----|-----------|
| Data sent to Anthropic API | Required for Claude to function | Block secrets with deny rules |
| Social engineering (you approve bad command) | Human problem | Read the workflow section above |
| Anthropic data breach | Outside your control | Don't expose secrets to Claude |
| Zero-day in bubblewrap/Seatbelt | Kernel-level bug | Defense in depth; monitor for patches |
| Claude Code auto-update changing behavior | npm update | Pin your Claude Code version |

### Defense Layers (13 independent)

| # | Layer | Mechanism |
|---|-------|-----------|
| 1 | External sandbox (bwrap/Seatbelt) | OS-level namespace/profile |
| 2 | Claude Code internal sandbox | Built-in `/sandbox` (redundant) |
| 3 | Network namespace / Seatbelt deny | Kernel-level network isolation |
| 4 | Egress proxy | Domain allowlist + audit logging |
| 5 | Two-stage socat bridge / localhost restriction | Only path from sandbox to network |
| 6 | Blocked paths | Secrets bound to /dev/null or Seatbelt deny |
| 7 | Read-only mounts (`/etc`, `/usr`, `/nix`) | System paths cannot be modified |
| 8 | Writable workspace only | Changes contained to review directory |
| 9 | Ephemeral /tmp | No session persistence |
| 10 | Audit logging | Every request recorded for review |
| 11 | Propose-review-apply workflow | Human gate before system changes |
| 12 | Session hygiene | Fresh sessions prevent context pollution |
| 13 | Nix reproducibility | Pinned deps, no supply chain drift |

No single layer is sufficient. Together, an attacker must bypass multiple
independent mechanisms simultaneously.


---

## License

MIT. Use at your own risk. This is a security tool — verify it works for your
threat model before relying on it.


---

## Acknowledgments

Built on the work of:

- [Anthropic sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) — the open-source sandboxing library
- [matgawin/bubblewrap-claude](https://github.com/matgawin/bubblewrap-claude) — Nix flake with profile architecture
- [nikvdp/cco](https://github.com/nikvdp/cco) — cross-platform Claude wrapper
- [neko-kai/claude-code-sandbox](https://github.com/neko-kai/claude-code-sandbox) — strict macOS Seatbelt profiles
- [Patrick McCanna](https://patrickmccanna.dev/) — argument for external wrapping
- [Pierce Freeman](https://pierce.dev/notes/a-deep-dive-on-agent-sandboxes) — deep dive on sandbox mechanisms
