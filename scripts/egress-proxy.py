#!/usr/bin/env python3
"""
Cross-platform egress filtering proxy for Claude Code sandbox.

Enforces a domain allowlist and logs all requests for audit.
Works on Linux, macOS, and any platform with Python 3.8+.
No external dependencies — stdlib only.

Supports:
  - HTTP CONNECT tunneling (for HTTPS traffic)
  - Plain HTTP proxying (GET, POST, etc.)
  - Domain allowlist with subdomain matching
  - Audit logging with timestamps
"""

import argparse
import http.server
import json
import select
import socket
import socketserver
import sys
import threading
import time
from datetime import datetime, timezone


# ══════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════

class ProxyConfig:
    def __init__(self, allowed_domains, audit_log_path, json_audit=False):
        self.allowed_domains = set(d.lower().strip(".") for d in allowed_domains)
        self.audit_log_path = audit_log_path
        self.json_audit = json_audit
        self._audit_file = None
        self._lock = threading.Lock()

    def is_allowed(self, hostname):
        """Check if hostname matches any allowed domain (including subdomains)."""
        hostname = hostname.lower().strip(".")
        for domain in self.allowed_domains:
            if hostname == domain or hostname.endswith("." + domain):
                return True
        return False

    def audit(self, method, host, result):
        """Thread-safe audit logging."""
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Parse host:port if present
        if ":" in host:
            hostname, port_str = host.rsplit(":", 1)
            try:
                port = int(port_str)
            except ValueError:
                hostname, port = host, None
        else:
            hostname, port = host, None

        if self.json_audit:
            entry = {
                "ts": ts,
                "result": result,
                "method": method,
                "host": hostname,
            }
            if port is not None:
                entry["port"] = port
            line = json.dumps(entry, separators=(",", ":")) + "\n"
        else:
            line = f"{ts} {result:7s} {method:7s} {host}\n"

        with self._lock:
            if self._audit_file is None and self.audit_log_path:
                try:
                    self._audit_file = open(self.audit_log_path, "a", buffering=1)
                except OSError as e:
                    print(f"[ERROR] Cannot open audit log: {e}", file=sys.stderr)

            if self._audit_file:
                self._audit_file.write(line)

        tag = "BLOCK" if result == "BLOCKED" else "PROXY"
        print(f"[{tag}] {ts} {method:7s} {host}", file=sys.stderr)


# ══════════════════════════════════════════════════════════════
# HTTP/HTTPS Proxy (CONNECT tunneling)
# ══════════════════════════════════════════════════════════════

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Handles HTTP CONNECT (HTTPS) and plain HTTP proxy requests."""

    # Suppress default logging
    def log_message(self, format, *args):
        pass

    def do_CONNECT(self):
        host_port = self.path
        host, _, port_str = host_port.partition(":")
        port = int(port_str) if port_str else 443

        if not self.server.config.is_allowed(host):
            self.server.config.audit("CONNECT", host_port, "BLOCKED")
            self.send_error(403, f"Blocked by sandbox: {host}")
            return

        self.server.config.audit("CONNECT", host_port, "ALLOWED")

        try:
            remote = socket.create_connection((host, port), timeout=15)
        except Exception as e:
            self.send_error(502, f"Cannot connect to {host}:{port}: {e}")
            return

        self.send_response(200, "Connection Established")
        self.end_headers()

        _tunnel(self.connection, remote)
        remote.close()

    # Forward plain HTTP methods through the proxy
    def do_GET(self):     self._proxy_plain()
    def do_POST(self):    self._proxy_plain()
    def do_PUT(self):     self._proxy_plain()
    def do_DELETE(self):  self._proxy_plain()
    def do_HEAD(self):    self._proxy_plain()
    def do_PATCH(self):   self._proxy_plain()
    def do_OPTIONS(self): self._proxy_plain()

    def _proxy_plain(self):
        """Forward a plain HTTP request (non-CONNECT)."""
        from urllib.parse import urlparse
        url = urlparse(self.path)
        host = url.hostname or ""
        port = url.port or 80

        if not self.server.config.is_allowed(host):
            self.server.config.audit(self.command, host, "BLOCKED")
            self.send_error(403, f"Blocked by sandbox: {host}")
            return

        self.server.config.audit(self.command, host, "ALLOWED")

        try:
            remote = socket.create_connection((host, port), timeout=15)

            # Reconstruct the request line with just the path
            path = url.path or "/"
            if url.query:
                path += "?" + url.query
            request_line = f"{self.command} {path} {self.request_version}\r\n"
            remote.sendall(request_line.encode())

            # Forward headers
            for key, val in self.headers.items():
                remote.sendall(f"{key}: {val}\r\n".encode())
            remote.sendall(b"\r\n")

            # Forward body if present
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length > 0:
                body = self.rfile.read(content_length)
                remote.sendall(body)

            # Relay response back
            while True:
                chunk = remote.recv(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)

            remote.close()
        except Exception as e:
            self.send_error(502, f"Proxy error: {e}")


# ══════════════════════════════════════════════════════════════
# Shared: bidirectional tunnel
# ══════════════════════════════════════════════════════════════

def _tunnel(sock_a, sock_b, timeout=120):
    """Relay data between two sockets until one closes."""
    sockets = [sock_a, sock_b]
    while True:
        try:
            readable, _, errors = select.select(sockets, [], sockets, timeout)
        except (ValueError, OSError):
            break
        if errors or not readable:
            break
        for sock in readable:
            other = sock_b if sock is sock_a else sock_a
            try:
                data = sock.recv(65536)
                if not data:
                    return
                other.sendall(data)
            except (OSError, BrokenPipeError):
                return


# ══════════════════════════════════════════════════════════════
# Server classes
# ══════════════════════════════════════════════════════════════

class ThreadedHTTPProxy(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler_class, config):
        self.config = config
        super().__init__(addr, handler_class)


# ══════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="Egress filtering proxy — domain allowlist + audit"
    )
    parser.add_argument(
        "--port", type=int, required=True,
        help="HTTP proxy listen port"
    )
    parser.add_argument(
        "--allow", action="append", default=[],
        help="Allowed domain (repeatable). Subdomains are included."
    )
    parser.add_argument(
        "--audit-log", default="",
        help="Path to audit log file"
    )
    parser.add_argument(
        "--json-audit", action="store_true",
        help="Output audit log in JSON-lines format (default: text)"
    )
    args = parser.parse_args()

    if not args.allow:
        print(
            "WARNING: No --allow domains specified. "
            "ALL requests will be BLOCKED.",
            file=sys.stderr,
        )

    config = ProxyConfig(args.allow, args.audit_log, args.json_audit)

    # Start HTTP/CONNECT proxy
    http_server = ThreadedHTTPProxy(
        ("127.0.0.1", args.port), ProxyHandler, config
    )
    http_thread = threading.Thread(target=http_server.serve_forever, daemon=True)
    http_thread.start()
    print(f"[PROXY] HTTP proxy on 127.0.0.1:{args.port}", file=sys.stderr)

    domains = ", ".join(args.allow) if args.allow else "(none — all blocked)"
    print(f"[PROXY] Allowed domains: {domains}", file=sys.stderr)
    print(f"[PROXY] Audit log: {args.audit_log or '(stderr only)'}", file=sys.stderr)

    # Run until killed
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\n[PROXY] Shutting down.", file=sys.stderr)


if __name__ == "__main__":
    main()
