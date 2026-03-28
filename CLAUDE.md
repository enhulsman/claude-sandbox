# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Sandbox is a cross-platform, defense-in-depth sandboxing wrapper for Claude Code. It enforces OS-level filesystem isolation, network filtering, and audit logging using bubblewrap (Linux) and Seatbelt/sandbox-exec (macOS). The external sandbox operates independently from Claude Code's internal sandbox, so even if the internal sandbox is bypassed, the external wrapper still holds.

## Build & Run Commands

```bash
# Enter dev shell with all tools available
nix develop

# Run sandboxed Claude Code with a profile
nix run . -- --profile dev

# Preview configuration without executing (dry run)
nix run . -- --profile dev --dry-run

# Run isolation verification tests (inside sandbox)
nix run . -- --profile dev --exec bash scripts/verify.sh

# Run verify tests on host (without sandbox — useful for baseline comparison)
nix run .#verify

# Update all flake dependencies (nixpkgs, claude-code-nix, etc.)
nix flake update
```

There is no separate build step — Nix handles everything declaratively via the flake.

## Architecture

### Execution Flow

```
claude-sandbox.sh (launcher)
  ├─ Parses args, loads profile from config.toml (TOML parsed via awk)
  ├─ Starts egress-proxy.py on a random free port
  ├─ Dispatches to platform-specific sandbox:
  │   ├─ linux-sandbox.sh → bubblewrap (--unshare-net for kernel-level network isolation)
  │   └─ macos-sandbox.sh → sandbox-exec with generated Seatbelt profile
  └─ On exit: kills proxy, prints session summary (allowed/blocked counts)
```

### Network Data Flow (Linux)

Claude Code cannot reach the network directly. All traffic is routed through the egress proxy via a two-stage socat bridge (needed because Node.js doesn't support Unix socket proxy URLs):

```
Claude Code → TCP:127.0.0.1:18080 (inside sandbox, socat)
  → Unix socket (bind-mounted through bubblewrap)
  → TCP:127.0.0.1:$PROXY_PORT (host socat)
  → egress-proxy.py (domain allowlist check)
  → upstream network
```

On macOS, Seatbelt restricts outbound to localhost:PROXY_PORT only; HTTP_PROXY env vars route traffic through the proxy.

### Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/claude-sandbox.sh` | Main launcher: arg parsing, config loading, proxy lifecycle |
| `scripts/linux-sandbox.sh` | Linux sandbox via bubblewrap: bind mounts, network namespace, socat bridge |
| `scripts/macos-sandbox.sh` | macOS sandbox via sandbox-exec with Seatbelt profiles |
| `scripts/generate-seatbelt.sh` | Generates LISP-based Seatbelt (.sb) policy files |
| `scripts/egress-proxy.py` | Network proxy: HTTP CONNECT, plain HTTP, SOCKS5; domain allowlist; audit logging |
| `scripts/verify.sh` | Isolation verification: filesystem, network, and privilege tests |

### Configuration

Profiles are defined in `config.toml` with three sections per profile:

- **filesystem.read_only** — paths mounted read-only inside the sandbox
- **filesystem.blocked** — paths bound to /dev/null (inaccessible)
- **filesystem.writable** — paths with write access (workspace is always writable)
- **network.allowed_domains** — domain allowlist with automatic subdomain matching

Built-in profiles: `dev` (development work), `nixos-admin`, `macos-admin`, `strict` (minimal access).

## Platform-Specific Notes

- **Linux (bubblewrap):** Entry script brings up loopback (`ip link set lo up`) inside the empty network namespace. Handles usr-merge systems (Debian 12+, Raspberry Pi) where `/bin` → `/usr/bin`.
- **macOS (Seatbelt):** Uses undocumented but functional `(allow default)` strategy — starts permissive, then denies network and file-write, then pokes specific holes. Cannot enforce DNS isolation at kernel level (proxy filters instead).

## Dependencies

Defined entirely in `flake.nix`. The egress proxy uses only Python stdlib (no external packages). Key runtime deps: bubblewrap and socat (Linux), python3, coreutils, bash, curl. Claude Code itself comes from the `claude-code-nix` flake input.

## Testing

`scripts/verify.sh` tests filesystem isolation (SSH keys, /etc/shadow, GPG, AWS creds blocked), network isolation (ping, non-allowed domains, DNS exfiltration), and privilege escalation (sudo, remount, user creation). Tests are platform-aware and skip Linux-specific checks on macOS.

## Security Considerations

### Network Access Warning

Allowed domains have **full bidirectional access** (GET, POST, PUT, DELETE) over HTTPS.
The proxy cannot filter HTTP methods inside TLS tunnels — HTTPS uses CONNECT tunneling
where the proxy only sees encrypted bytes after the connection is established.

**If you allow a domain, assume Claude can POST data to it.**

### MCP Security

MCPs (Model Context Protocol servers) run as separate processes on the **HOST**, not inside the sandbox:
- MCPs can access the network directly (bypassing the egress proxy)
- MCPs can read files blocked by the sandbox
- MCPs may fail if their required env vars aren't in the passthrough list

**Recommendations:**
- Avoid MCPs in high-security scenarios
- If using MCPs, add required vars to `[profile.*.environment.passthrough]`
- Audit MCP code before trusting it

### Git Security

Git configuration (~/.gitconfig) is readable inside the sandbox for normal operations.

**Security implications:**
- SSH remotes (`git@github.com:...`) are safe — SSH keys are blocked
- HTTPS remotes with embedded tokens (`https://TOKEN@github.com/...`) are readable

Check your remotes: `git remote -v`

### macOS Security Note

We attempt to protect `~/.claude/settings.json` via Seatbelt's `(deny file-write*)`,
but Seatbelt's literal matching has quirks and may not be 100% reliable. For maximum
security on macOS, audit settings.json after high-risk sessions, or use Linux for
security-critical work.

### settings.json Protection

The file `~/.claude/settings.json` contains security-critical deny rules that control
what Claude Code is allowed to do. On Linux, this file is mounted read-only inside
the sandbox to prevent prompt injection attacks from removing deny rules.

### ~/.claude.json (Account State)

This file is copied into the sandbox at launch rather than bind-mounted. Individual
file bind mounts go stale when the file is atomically replaced on the host (new inode,
old mount points at deleted data). Changes to `~/.claude.json` inside the sandbox
(e.g., `/login`) do not propagate back to the host — restart the sandbox to pick up
account changes.
