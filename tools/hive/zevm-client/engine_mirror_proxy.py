#!/usr/bin/env python3
import argparse
import base64
import hashlib
import hmac
import http.client
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MIRRORED_PREFIXES = ("engine_newPayload", "engine_forkchoiceUpdated")


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def jwt_token(secret):
    now = int(time.time())
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({"iat": now, "exp": now + 60}, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()
    signature = b64url(hmac.new(secret, signing_input, hashlib.sha256).digest())
    return f"{header}.{payload}.{signature}"


def rpc_items(body):
    try:
        decoded = json.loads(body)
    except json.JSONDecodeError:
        return []
    if isinstance(decoded, list):
        return [item for item in decoded if isinstance(item, dict)]
    if isinstance(decoded, dict):
        return [decoded]
    return []


def should_mirror_request(body, response_body):
    requests = rpc_items(body)
    if not any(str(item.get("method", "")).startswith(MIRRORED_PREFIXES) for item in requests):
        return False
    try:
        response = json.loads(response_body)
    except json.JSONDecodeError:
        return False
    responses = response if isinstance(response, list) else [response]
    by_id = {item.get("id"): item for item in responses if isinstance(item, dict)}
    for request in requests:
        method = str(request.get("method", ""))
        if not method.startswith(MIRRORED_PREFIXES):
            continue
        response_item = by_id.get(request.get("id"))
        if not isinstance(response_item, dict) or "error" in response_item:
            continue
        result = response_item.get("result")
        if method.startswith("engine_newPayload") and isinstance(result, dict):
            if result.get("status") in {"VALID", "ACCEPTED"}:
                return True
        if method.startswith("engine_forkchoiceUpdated") and isinstance(result, dict):
            payload_status = result.get("payloadStatus")
            if isinstance(payload_status, dict) and payload_status.get("status") == "VALID":
                return True
    return False


def forward(port, body, headers):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    try:
        conn.request("POST", "/", body=body, headers=headers)
        response = conn.getresponse()
        response_body = response.read()
        return response.status, response.reason, response.getheaders(), response_body
    finally:
        conn.close()


class EngineMirrorProxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path != "/healthz":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return

        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"connection", "content-length", "host", "transfer-encoding"}
        }
        headers["Host"] = f"127.0.0.1:{self.server.primary_port}"
        headers["Content-Length"] = str(len(body))

        status, reason, response_headers, response_body = forward(self.server.primary_port, body, headers)
        if should_mirror_request(body, response_body):
            mirror_headers = dict(headers)
            mirror_headers["Host"] = f"127.0.0.1:{self.server.mirror_port}"
            mirror_headers["Authorization"] = f"Bearer {jwt_token(self.server.jwt_secret)}"
            try:
                forward(self.server.mirror_port, body, mirror_headers)
            except Exception:
                pass

        self.send_response(status, reason)
        for key, value in response_headers:
            if key.lower() not in {"connection", "content-length", "transfer-encoding"}:
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(response_body)

    def log_message(self, fmt, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--primary-port", type=int, required=True)
    parser.add_argument("--mirror-port", type=int, required=True)
    parser.add_argument("--jwt-secret-file", required=True)
    args = parser.parse_args()

    with open(args.jwt_secret_file, "r", encoding="ascii") as secret_file:
        secret = bytes.fromhex(secret_file.read().strip())

    server = ThreadingHTTPServer((args.listen_host, args.listen_port), EngineMirrorProxy)
    server.primary_port = args.primary_port
    server.mirror_port = args.mirror_port
    server.jwt_secret = secret
    server.serve_forever()


if __name__ == "__main__":
    main()
