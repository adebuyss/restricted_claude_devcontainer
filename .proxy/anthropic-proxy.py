#!/usr/bin/env python3
"""
Reverse proxy for Anthropic API that injects the API key.

This proxy sits between Claude Code and api.anthropic.com, injecting the
x-api-key header so the API key never needs to exist in the Claude container.

If ANTHROPIC_API_KEY is not set, requests pass through without injection
(allowing OAuth or other auth methods to work normally).

Supports streaming SSE responses for Claude's streaming API.
"""

from __future__ import annotations

import http.client
import http.server
import os
import socket
import ssl
import sys
import threading
from typing import Any

ANTHROPIC_HOST = "api.anthropic.com"
ANTHROPIC_PORT = 443
LISTEN_PORT = int(os.environ.get("ANTHROPIC_PROXY_PORT", 3129))
API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

# Headers that should not be forwarded
SKIP_REQUEST_HEADERS = {"host", "transfer-encoding"}
SKIP_RESPONSE_HEADERS = {"transfer-encoding", "connection"}


class AnthropicProxyHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler that proxies to Anthropic API with key injection."""

    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        """Log without exposing sensitive data."""
        sys.stderr.write(f"[anthropic-proxy] {args[0]}\n")

    def _proxy_request(self, method: str) -> None:
        """Proxy a request to Anthropic API."""
        # Read request body if present
        content_length = self.headers.get("Content-Length")
        body = None
        if content_length:
            body = self.rfile.read(int(content_length))

        # Create SSL context
        ssl_context = ssl.create_default_context()

        try:
            # Connect to Anthropic
            conn = http.client.HTTPSConnection(
                ANTHROPIC_HOST, ANTHROPIC_PORT, context=ssl_context, timeout=300
            )

            # Build headers
            headers = {"Host": ANTHROPIC_HOST}

            # Inject API key if configured (and not already present in request)
            if API_KEY and not self.headers.get("x-api-key"):
                headers["x-api-key"] = API_KEY

            for header, value in self.headers.items():
                if header.lower() not in SKIP_REQUEST_HEADERS:
                    headers[header] = value

            # Make request
            conn.request(method, self.path, body=body, headers=headers)
            response = conn.getresponse()

            # Send response status
            self.send_response(response.status)

            # Forward response headers
            is_streaming = False
            for header, value in response.getheaders():
                if header.lower() not in SKIP_RESPONSE_HEADERS:
                    self.send_header(header, value)
                    if (
                        header.lower() == "content-type"
                        and "text/event-stream" in value
                    ):
                        is_streaming = True

            self.end_headers()

            # Stream response body
            if is_streaming:
                # SSE streaming - read and forward chunks
                while True:
                    chunk = response.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            else:
                # Regular response - read all and forward
                self.wfile.write(response.read())

            conn.close()

        except http.client.HTTPException as e:
            self.send_error(502, f"Upstream error: {e}")
        except ssl.SSLError as e:
            self.send_error(502, f"SSL error: {e}")
        except TimeoutError:
            self.send_error(504, "Upstream timeout")
        except Exception as e:
            self.send_error(500, f"Proxy error: {e}")

    def do_GET(self) -> None:
        self._proxy_request("GET")

    def do_POST(self) -> None:
        self._proxy_request("POST")

    def do_OPTIONS(self) -> None:
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()


class ThreadedHTTPServer(http.server.HTTPServer):
    """HTTP server that handles each request in a new thread."""

    daemon_threads = True

    def process_request(
        self, request: socket.socket | tuple[bytes, socket.socket], client_address: Any
    ) -> None:
        thread = threading.Thread(
            target=self._process_request_thread, args=(request, client_address)
        )
        thread.daemon = True
        thread.start()

    def _process_request_thread(
        self, request: socket.socket | tuple[bytes, socket.socket], client_address: Any
    ) -> None:
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


def main() -> None:
    if API_KEY:
        key_preview = API_KEY[:12] + "..." if len(API_KEY) > 12 else "***"
        print(
            f"[anthropic-proxy] API key injection enabled: {key_preview}",
            file=sys.stderr,
        )
    else:
        print(
            "[anthropic-proxy] No API key configured - passthrough mode",
            file=sys.stderr,
        )

    server = ThreadedHTTPServer(("0.0.0.0", LISTEN_PORT), AnthropicProxyHandler)
    print(f"[anthropic-proxy] Listening on port {LISTEN_PORT}", file=sys.stderr)
    print(
        f"[anthropic-proxy] Proxying to {ANTHROPIC_HOST}:{ANTHROPIC_PORT}",
        file=sys.stderr,
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[anthropic-proxy] Shutting down", file=sys.stderr)
        server.shutdown()


if __name__ == "__main__":
    main()
