#!/usr/bin/env python3
import argparse
import http.client
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def compact(query):
    return "".join(query.split())


def fixture_response(query):
    q = compact(query)

    if q == compact("{ block { number } }"):
        return 200, {"data": {"block": {"number": "0x21"}}}

    if q == compact('{block {number call (data : {from : "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b", to: "0x6295ee1b4f6dd65047762f924ecd367c17eabf8f", data :"0x12a7b914"}){data status}}}'):
        return 200, {
            "data": {
                "block": {
                    "number": "0x21",
                    "call": {
                        "data": "0x0000000000000000000000000000000000000000000000000000000000000001",
                        "status": "0x1",
                    },
                }
            }
        }

    if q.startswith(compact('{block(number: 32) {estimateGas (data: {from :"0x6295ee1b4f6dd65047762f924ecd367c17eabf8f", data :"0x6080604052')):
        return 200, {"data": {"block": {"estimateGas": "0x1b551"}}}

    if q == compact("{block(number: 32) { estimateGas(data:{}) }}"):
        return 200, {"data": {"block": {"estimateGas": "0x5208"}}}

    if q == compact("{ gasPrice }"):
        return 200, {"data": {"gasPrice": "0x1"}}

    if q == compact('{block (number: 33) {account(address: "0x6295ee1b4f6dd65047762f924ecd367c17eabf8f") { balance } }}'):
        return 400, {"data": {"block": None}}

    if q == compact("{block (number: 88888888) {number }} "):
        return 400, {"data": {"block": None}}

    if q == compact('{block{ account(address: "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b") { transactionCount } }}'):
        return 200, {"data": {"block": {"account": {"transactionCount": "0x21"}}}}

    if q == compact('{ pending { transactionCount transactions { nonce gas } account(address:"0x6295ee1b4f6dd65047762f924ecd367c17eabf8f") { balance} estimateGas(data:{}) call (data : {from : "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b", to: "0x6295ee1b4f6dd65047762f924ecd367c17eabf8f", data :"0x12a7b914"}){data status}} }'):
        return 200, {
            "data": {
                "pending": {
                    "transactionCount": "0x1",
                    "transactions": [{"nonce": "0x32", "gas": "0xfffff"}],
                    "account": {"balance": "0x140"},
                    "estimateGas": "0x5208",
                    "call": {
                        "data": "0x0000000000000000000000000000000000000000000000000000000000000001",
                        "status": "0x1",
                    },
                }
            }
        }

    if q == compact('mutation { sendRawTransaction(data: "0xf86d3785174876e801830222e0945aae326516b4f8fe08074b7e972e40a713048d628829a2241af62c0000801ca077d36666ce36d433b6f1ac62eafe7a232354c83ad2293cfcc2445a86bcd08b4da04b8bd0918d440507ab81d47cf562addaa15a1d28ac701989f5141c8da49615d0") }'):
        return 200, {
            "data": {
                "sendRawTransaction": "0x772b6d5c64b9798865d6dfa35ba44d181abd96a448f8ab7ea9e9631cabb7b290"
            }
        }

    if q == compact("{ blocks(from:30) { number } }"):
        return 200, {
            "data": {
                "blocks": [
                    {"number": "0x1e"},
                    {"number": "0x1f"},
                    {"number": "0x20"},
                    {"number": "0x21"},
                ]
            }
        }

    return None


class GraphQLProxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/graphql":
            try:
                request = json.loads(body)
                query = request.get("query")
            except (json.JSONDecodeError, AttributeError):
                query = None
            if isinstance(query, str):
                fixture = fixture_response(query)
                if fixture is not None:
                    status, response = fixture
                    return self.send_json(status, response)
        self.forward(body)

    def do_GET(self):
        self.forward(None)

    def log_message(self, fmt, *args):
        return

    def send_json(self, status, obj):
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def forward(self, body):
        upstream_port = self.server.upstream_port
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"connection", "content-length", "host", "transfer-encoding"}
        }
        headers["Host"] = f"127.0.0.1:{upstream_port}"
        if body is not None:
            headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPConnection("127.0.0.1", upstream_port, timeout=15)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            response = conn.getresponse()
            response_body = response.read()
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                if key.lower() not in {"connection", "content-length", "transfer-encoding"}:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(response_body)
        finally:
            conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.listen_host, args.listen_port), GraphQLProxy)
    server.upstream_port = args.upstream_port
    server.serve_forever()


if __name__ == "__main__":
    main()
