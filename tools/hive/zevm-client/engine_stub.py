#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json


class EngineHandler(BaseHTTPRequestHandler):
    server_version = "zevm-engine-stub/0.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            request = json.loads(body)
            response = self.handle_rpc(request)
            payload = json.dumps(response, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as exc:
            payload = json.dumps({
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32603, "message": str(exc)},
            }, separators=(",", ":")).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return

    def handle_rpc(self, request):
        if isinstance(request, list):
            return [self.handle_rpc(item) for item in request]

        method = request.get("method")
        request_id = request.get("id")
        if method in (
            "engine_forkchoiceUpdatedV1",
            "engine_forkchoiceUpdatedV2",
            "engine_forkchoiceUpdatedV3",
        ):
            params = request.get("params") or []
            head_hash = None
            if params and isinstance(params[0], dict):
                head_hash = params[0].get("headBlockHash")
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "payloadStatus": {
                        "status": "VALID",
                        "latestValidHash": head_hash,
                        "validationError": None,
                    },
                    "payloadId": None,
                },
            }
        if method == "engine_exchangeTransitionConfigurationV1":
            params = request.get("params") or [{}]
            return {"jsonrpc": "2.0", "id": request_id, "result": params[0]}

        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": "method not found"},
        }


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8551), EngineHandler).serve_forever()
