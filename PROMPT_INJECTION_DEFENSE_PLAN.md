# Prompt Injection Defense Plan

## Executive Summary

This plan addresses prompt injection vulnerabilities identified in the claude-sandbox project. The core insight: **prioritize OUTPUT-side restrictions (70%) over INPUT-side filtering (30%)** because output restrictions limit damage regardless of how Claude was compromised.

---

## Problems Identified

| # | Problem | Severity |
|---|---------|----------|
| 1 | No defense against prompt injection from allowed domains | CRITICAL |
| 2 | WebFetch/curl output goes directly to context unfiltered | CRITICAL |
| 3 | pretooluse-guard cannot catch semantic-level LLM attacks | MAJOR |
| 4 | Workspace + bidirectional domains = exfiltration staging | MAJOR |
| 5 | Anomaly detection is post-hoc only, not real-time | MAJOR |
| 6 | Sandbox context leaks defensive information | MINOR |

---

## Fix Plan

### Fix 1: Real-Time Anomaly Detection in Egress Proxy

**Addresses**: Problem 5 (post-hoc detection)

**What**: Add circuit-breaker logic to `scripts/egress-proxy.py` that pauses the proxy when suspicious patterns are detected in real-time.

**Implementation**:
- Track blocked requests per-domain in sliding window
- **Revised threshold**: 3+ blocked requests to the *same domain* in 10 seconds = suspicious (not raw count)
- Also trigger on: >10% block rate over 50+ requests (reuses existing `generate-report.sh` heuristics)
- Add a control mechanism (signal or socket) for pause/resume
- Print terminal warning when threshold hit
- Configurable thresholds in profile section of `config.toml`

**Files Modified**: `scripts/egress-proxy.py`, `config.toml` (new threshold options)

**Trade-offs**: May cause false positives if legitimate blocked domains are probed. Mitigated by per-domain tracking (not raw count) and configurable thresholds.

---

### Fix 2: HTTP Method Filtering per Domain

**Addresses**: Problem 4 (bidirectional exfiltration channels)

**What**: Extend egress proxy to filter by HTTP method, allowing read-only access to documentation domains.

**Implementation**:
- Add new config option: `network.fetch_only_domains` (GET/HEAD only)
- Modify proxy to parse HTTP method before relaying
- Block POST/PUT/DELETE to fetch-only domains
- Default: documentation domains (github.com, docs.*, etc.) are fetch-only
- Authenticated domains (registry.npmjs.org for publish) remain bidirectional

**Files Modified**: `config.toml`, `scripts/egress-proxy.py`

**Trade-offs**: Cannot push to GitHub from within sandbox. Acceptable for dev profile; users can push outside sandbox.

---

### Fix 3: Behavioral Budget Tracking

**Addresses**: Problem 3 (semantic attacks bypass pattern matching)

**What**: Track cumulative behavior and enforce limits regardless of how commands are constructed.

**Prerequisite**: Verify Claude Code hook capabilities before implementation.

**Implementation Path A** (if PostToolUse hooks exist):
- Add PostToolUse hook that logs tool invocations
- Track metrics: bytes written, files created, network requests
- Define budgets per time window (e.g., max 1MB written per minute)

**Implementation Path B** (if no PostToolUse hooks — more likely):
- Implement external filesystem watcher daemon using inotify (Linux) / FSEvents (macOS)
- Daemon writes state to JSON file in session directory: `$SESSION_DIR/budget-state.json`
- Proxy reads state file before processing requests
- Periodic polling interval: 5 seconds (balance responsiveness vs overhead)
- Daemon lifecycle managed by `claude-sandbox.sh` (start on session begin, kill on exit)

**Files Modified**: New `scripts/budget-daemon.py`, modify `scripts/claude-sandbox.sh`

**Trade-offs**: Path B adds daemon complexity. Start with generous limits (5MB/min writes, 200 requests/min) and tighten based on real usage. This fix is **deprioritized** until Path A/B is determined.

**Status**: BLOCKED pending Claude Code hook capability verification.

---

### Fix 4: Content Tagging for External Sources

**Addresses**: Problem 1, 2 (unfiltered external content)

**What**: Add metadata to web-fetched content so Claude is aware it's external and potentially untrusted.

**Limitation**: This only works for **plain HTTP traffic**. HTTPS traffic uses CONNECT tunneling where the proxy establishes the connection but never sees decrypted content. Most valuable domains (GitHub, npm, pypi) use HTTPS, so this fix has **limited coverage**.

**Implementation** (for plain HTTP only):
- Intercept non-CONNECT responses in proxy
- For HTML: inject `<!-- EXTERNAL CONTENT FROM: {domain} -->` at start
- For JSON/text: prepend `[EXTERNAL: {domain}]` marker
- Claude's system prompt can instruct it to treat marked content with skepticism

**Files Modified**: `scripts/egress-proxy.py`

**Trade-offs**:
- Only affects plain HTTP (minority of traffic)
- Markers could be stripped by sophisticated attacks
- This is defense-in-depth with **marginal benefit** given HTTPS prevalence

**Alternative considered**: MitM proxy with custom CA for HTTPS inspection. Rejected due to complexity and trust implications.

**Status**: LOW PRIORITY given limited HTTPS coverage. Implement only after higher-value fixes.

---

### Fix 5: Fetch-Only Profile Variant

**Addresses**: Problem 4 (channel separation)

**What**: Create a `dev-fetch` profile optimized for web research with minimal write/publish capability.

**Implementation**:
- New profile in `config.toml`: `dev-fetch`
- Network: All domains are GET-only except `api.anthropic.com`
- Filesystem: Workspace is read-only except for a small scratch area
- Use case: Safe web research mode

**Files Modified**: `config.toml`

**Trade-offs**: Less functional than full `dev` profile. Users choose based on task.

---

### Fix 6: Write-Then-POST Detection

**Addresses**: Problem 4 (exfiltration pattern detection)

**What**: Detect the specific pattern of "write to workspace, then POST to network" which suggests data staging for exfiltration.

**Architecture** (cross-component coordination):
```
Filesystem Watcher ──writes to──> $SESSION_DIR/workspace-mtime
                                         │
Egress Proxy ───────reads from───────────┘
                     │
                     └──> If POST within N seconds of mtime: flag suspicious
```

**Implementation**:
1. Filesystem watcher (same daemon as Fix 3, if implemented) updates `workspace-mtime` file on any write to workspace
2. Alternatively: simple approach using `stat` on workspace directory mtime (no daemon needed, less precise)
3. Proxy checks mtime before processing POST/PUT requests
4. If POST occurs within 30 seconds of workspace modification: log warning
5. Optional: pause and alert (configurable)

**Files Modified**: `scripts/egress-proxy.py`, possibly `scripts/budget-daemon.py` (shared infrastructure with Fix 3)

**Trade-offs**:
- False positives when legitimately saving and pushing (common workflow)
- Mitigated by: logging-only mode by default, pause is opt-in
- Simple mtime approach may miss rapid write-then-POST within same second

**Dependency**: Shares infrastructure with Fix 3. If Fix 3 uses daemon, this piggybacks. If not, use simple mtime polling.

**Known Limitation**: The simple mtime approach has a ~1-second blind spot. If write-then-POST occurs within the same filesystem second, it won't be detected. This is acceptable initially; upgrade to daemon-based tracking when Fix 3 infrastructure is available for sub-second precision.

---

### Fix 7: Reduce Information Leakage in Sandbox Context

**Addresses**: Problem 6 (defensive info leakage)

**What**: Remove error message predictions from sandbox context while keeping path information.

**Revised approach**: The specific blocked path list (`~/.ssh`, `~/.gnupg`, etc.) is useful for legitimate Claude operation and isn't truly secret (anyone can read `config.toml`). However, error message predictions ("will return Permission denied") provide marginal attack surface for fingerprinting.

**Implementation**:
- Keep specific blocked path lists (Claude needs this to avoid wasting tool calls)
- Remove error message predictions from context
- Before: `Blocked paths (will return "No such file" or "Permission denied"):`
- After: `Blocked paths (access will be denied):`

**Files Modified**: `scripts/claude-sandbox.sh` (context generation section)

**Trade-offs**: Minimal security gain, minimal usability loss. Do this as a minor cleanup, not a priority.

**Status**: LOW PRIORITY. Marginal improvement only.

---

## Revised Priority Order

1. **Fix 2** (HTTP method filtering) - Medium effort, closes exfil channel, no blockers
2. **Fix 5** (fetch-only profile) - Low effort, gives users safe option, no blockers
3. **Fix 1** (real-time anomaly detection) - Revised thresholds, quick win
4. **Fix 6** (write-then-POST detection) - Simple mtime approach first, daemon later
5. **Fix 3** (behavioral budgets) - BLOCKED pending hook verification, deprioritized
6. **Fix 7** (reduce info leakage) - Minor cleanup, do when convenient
7. **Fix 4** (content tagging) - LOW VALUE due to HTTPS limitation, skip unless HTTP-heavy use case

---

## What This Plan Does NOT Address

- **Content sanitization/filtering**: Deliberately omitted. Stripping injection payloads is an arms race we won't win. Focus on limiting damage instead.
- **Claude Code internals**: We can't modify Claude Code itself. We work with what we can control (sandbox, proxy, hooks).
- **Targeted attacks via dependency chain**: Different threat model requiring package provenance verification.

---

## Validation Approach

For each fix:
1. Create test cases simulating prompt injection scenarios
2. Verify the defense triggers appropriately
3. Verify legitimate workflows still function
4. Document in `scripts/verify.sh` or new test script

---

## Open Questions for User

1. Should github.com be fetch-only by default, or do you need push capability from within the sandbox?
   *(Recommended: Yes, fetch-only. Push operations can happen outside the sandbox.)*

2. What behavioral budget thresholds feel right? (e.g., 5MB/min writes, 200 requests/min)?
   *(Recommended: Start with these generous limits and tighten based on real usage.)*

3. Is a "pause and alert" response acceptable, or do you prefer "log and continue"?
   *(Recommended: Log and continue by default. Pause is opt-in via config.)*

4. For Fix 6 (write-then-POST): Is logging-only acceptable, or do you want pause capability?
   *(Recommended: Logging-only default, consistent with #3.)*

---

## Platform Considerations

**Note**: This plan focused on Linux (bubblewrap). The macOS Seatbelt implementation (`macos-sandbox.sh`, `generate-seatbelt.sh`) may have different constraints:
- Seatbelt uses `(allow default)` with deny overrides — different enforcement model
- FSEvents vs inotify for filesystem watching
- Fixes should be tested on both platforms before deployment

**Implementation requirement**: Each fix PR must include macOS testing, or explicitly document "Linux-only pending macOS adaptation" if platform-specific blockers exist.
