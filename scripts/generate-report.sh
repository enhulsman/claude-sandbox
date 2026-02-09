#!/usr/bin/env bash
# generate-report.sh — Generate session report from audit log
#
# Usage: generate-report.sh <audit-log> <output-json> [duration-seconds] [profile] [workspace]
#
# Parses the audit log and generates a JSON session report with:
#   - Request counts (total, allowed, blocked)
#   - Per-domain breakdown
#   - Suspicious pattern detection
#   - Risk score calculation

set -euo pipefail

AUDIT_LOG="${1:-}"
OUTPUT="${2:-}"
DURATION="${3:-0}"
PROFILE="${4:-unknown}"
WORKSPACE="${5:-}"
RECOGNIZED_DOMAINS_STR="${6:-}"

if [[ -z "$AUDIT_LOG" || -z "$OUTPUT" ]]; then
  echo "Usage: generate-report.sh <audit-log> <output-json> [duration] [profile] [workspace]" >&2
  exit 1
fi

# Extract session ID from audit log path if possible
SESSION_ID=""
if [[ "$AUDIT_LOG" =~ \.sessions/([0-9-]+)/ ]]; then
  SESSION_ID="${BASH_REMATCH[1]}"
fi

# Calculate timestamps
END_TIME=$(date +%s)
END_TIME_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [[ "$DURATION" -gt 0 ]]; then
  START_TIME=$((END_TIME - DURATION))
  START_TIME_ISO=$(date -u -d "@$START_TIME" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                   date -u -r "$START_TIME" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                   echo "unknown")
else
  START_TIME_ISO="unknown"
fi

# Parse audit log and generate report using awk
# Handles both text format: "2026-02-03T14:30:22Z ALLOWED CONNECT api.anthropic.com:443"
# and JSON format: {"ts":"...","result":"ALLOWED","method":"CONNECT","host":"...","port":443}
awk -v session_id="$SESSION_ID" \
    -v profile="$PROFILE" \
    -v start_time="$START_TIME_ISO" \
    -v end_time="$END_TIME_ISO" \
    -v duration="$DURATION" \
    -v workspace="$WORKSPACE" \
    -v recognized_str="$RECOGNIZED_DOMAINS_STR" \
'
BEGIN {
  total = 0
  allowed = 0
  blocked = 0
  recognized_blocked = 0

  # Initialize arrays
  split("", domain_allowed)
  split("", domain_blocked)
  split("", methods)
  split("", blocked_domains)
  split("", ip_ports)

  # Build recognized domains set
  split("", recognized_domains)
  n_recog = split(recognized_str, recog_arr, "\n")
  for (i = 1; i <= n_recog; i++) {
    d = recog_arr[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", d)
    gsub(/^\.+|\.+$/, "", d)
    if (d != "") recognized_domains[d] = 1
  }
}

# NOTE: is_recognized() logic duplicated in claude-sandbox.sh — keep in sync
function is_recognized(host,    h, d) {
  h = tolower(host); gsub(/\.$/, "", h)
  for (d in recognized_domains) {
    if (h == d || (length(h) > length(d) && substr(h, length(h) - length(d)) == "." d))
      return 1
  }
  return 0
}

# JSON format detection
/^\{.*"ts".*\}$/ {
  # Parse JSON line (simple extraction without jq)
  json = $0

  # Extract result
  if (match(json, /"result":"([^"]+)"/, m)) {
    result = m[1]
  } else {
    next
  }

  # Extract method
  if (match(json, /"method":"([^"]+)"/, m)) {
    method = m[1]
  } else {
    method = "UNKNOWN"
  }

  # Extract host
  if (match(json, /"host":"([^"]+)"/, m)) {
    host = m[1]
  } else {
    next
  }

  # Extract port (optional)
  port = ""
  if (match(json, /"port":([0-9]+)/, m)) {
    port = m[1]
  }

  process_entry(result, method, host, port)
  next
}

# Text format: timestamp result method host[:port]
/^[0-9]{4}-[0-9]{2}-[0-9]{2}T/ {
  result = $2
  method = $3
  hostport = $4

  # Split host:port
  n = split(hostport, hp, ":")
  host = hp[1]
  port = (n > 1) ? hp[2] : ""

  process_entry(result, method, host, port)
  next
}

function process_entry(result, method, host, port) {
  total++
  methods[method]++

  if (result == "ALLOWED") {
    allowed++
    domain_allowed[host]++
  } else if (result == "BLOCKED") {
    blocked++
    domain_blocked[host]++
    blocked_domains[host]++
    if (is_recognized(host)) recognized_blocked++
  }

  # Track IP access with ports (for port scanning detection)
  if (host ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && port != "") {
    ip_ports[host ":" port]++
  }
}

function json_escape(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\n/, "\\n", s)
  gsub(/\r/, "\\r", s)
  gsub(/\t/, "\\t", s)
  return s
}

END {
  # Calculate risk score and detect suspicious patterns
  risk_score = 0
  suspicious_count = 0
  suspicious_json = ""

  # Pattern 1: Repeated blocks on same domain (>3 = HIGH), skip recognized domains
  for (domain in blocked_domains) {
    if (blocked_domains[domain] > 3 && !is_recognized(domain)) {
      risk_score += 25
      suspicious_count++
      if (suspicious_json != "") suspicious_json = suspicious_json ","
      suspicious_json = suspicious_json sprintf("{\"type\":\"repeated_blocks\",\"domain\":\"%s\",\"count\":%d,\"severity\":\"high\",\"description\":\"Repeated attempts to blocked domain\"}", json_escape(domain), blocked_domains[domain])
    }
  }

  # Pattern 2: High block rate (>10% = MEDIUM), using only unknown (non-recognized) blocks
  unknown_blocked = blocked - recognized_blocked
  if (total > 10 && unknown_blocked / total > 0.1) {
    risk_score += 15
    suspicious_count++
    if (suspicious_json != "") suspicious_json = suspicious_json ","
    block_pct = int(unknown_blocked * 100 / total)
    suspicious_json = suspicious_json sprintf("{\"type\":\"high_block_rate\",\"blocked_percent\":%d,\"severity\":\"medium\",\"description\":\"Unusually high blocked request ratio\"}", block_pct)
  }

  # Pattern 3: Direct IP access (any = LOW)
  ip_count = 0
  for (ip_port in ip_ports) {
    ip_count++
  }
  if (ip_count > 0) {
    risk_score += 5
    suspicious_count++
    if (suspicious_json != "") suspicious_json = suspicious_json ","
    suspicious_json = suspicious_json sprintf("{\"type\":\"direct_ip_access\",\"unique_ip_ports\":%d,\"severity\":\"low\",\"description\":\"Direct IP access bypasses domain filtering\"}", ip_count)
  }

  # Pattern 4: Port scanning (>2 ports same IP = MEDIUM)
  split("", ip_port_counts)
  for (ip_port in ip_ports) {
    split(ip_port, parts, ":")
    ip = parts[1]
    ip_port_counts[ip]++
  }
  for (ip in ip_port_counts) {
    if (ip_port_counts[ip] > 2) {
      risk_score += 20
      suspicious_count++
      if (suspicious_json != "") suspicious_json = suspicious_json ","
      suspicious_json = suspicious_json sprintf("{\"type\":\"port_scanning\",\"ip\":\"%s\",\"port_count\":%d,\"severity\":\"medium\",\"description\":\"Multiple ports accessed on same IP\"}", json_escape(ip), ip_port_counts[ip])
    }
  }

  # Pattern 5: High request volume (>500 = INFO)
  if (total > 500) {
    risk_score += 5
    suspicious_count++
    if (suspicious_json != "") suspicious_json = suspicious_json ","
    suspicious_json = suspicious_json sprintf("{\"type\":\"high_volume\",\"total_requests\":%d,\"severity\":\"info\",\"description\":\"Unusually active session\"}", total)
  }

  # Cap risk score at 100
  if (risk_score > 100) risk_score = 100

  # Determine risk level
  if (risk_score >= 50) {
    risk_level = "high"
  } else if (risk_score >= 25) {
    risk_level = "medium"
  } else if (risk_score > 0) {
    risk_level = "low"
  } else {
    risk_level = "none"
  }

  # Build by_domain JSON
  by_domain = ""
  for (domain in domain_allowed) {
    if (by_domain != "") by_domain = by_domain ","
    dom_blocked = (domain in domain_blocked) ? domain_blocked[domain] : 0
    by_domain = by_domain sprintf("\"%s\":{\"allowed\":%d,\"blocked\":%d}", json_escape(domain), domain_allowed[domain], dom_blocked)
  }
  for (domain in domain_blocked) {
    if (!(domain in domain_allowed)) {
      if (by_domain != "") by_domain = by_domain ","
      by_domain = by_domain sprintf("\"%s\":{\"allowed\":0,\"blocked\":%d}", json_escape(domain), domain_blocked[domain])
    }
  }

  # Build by_method JSON
  by_method = ""
  for (method in methods) {
    if (by_method != "") by_method = by_method ","
    by_method = by_method sprintf("\"%s\":%d", json_escape(method), methods[method])
  }

  # Output JSON report
  printf "{\n"
  printf "  \"session\": {\n"
  printf "    \"id\": \"%s\",\n", json_escape(session_id)
  printf "    \"profile\": \"%s\",\n", json_escape(profile)
  printf "    \"started\": \"%s\",\n", start_time
  printf "    \"ended\": \"%s\",\n", end_time
  printf "    \"duration_seconds\": %d,\n", duration
  printf "    \"workspace\": \"%s\"\n", json_escape(workspace)
  printf "  },\n"
  printf "  \"network\": {\n"
  printf "    \"total\": %d,\n", total
  printf "    \"allowed\": %d,\n", allowed
  printf "    \"blocked\": %d,\n", blocked
  printf "    \"blocked_recognized\": %d,\n", recognized_blocked
  printf "    \"blocked_unknown\": %d,\n", blocked - recognized_blocked
  printf "    \"by_domain\": {%s},\n", by_domain
  printf "    \"by_method\": {%s}\n", by_method
  printf "  },\n"
  printf "  \"suspicious\": [%s],\n", suspicious_json
  printf "  \"risk_score\": %d,\n", risk_score
  printf "  \"risk_level\": \"%s\"\n", risk_level
  printf "}\n"
}
' "$AUDIT_LOG" > "$OUTPUT"
