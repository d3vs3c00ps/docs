"""A small HTTPS API for tests/linux/cli/hurl.sh, on port 443, for the note's hosts."""
import http.server
import json
import ssl
import sys

TOKEN = "tok-123"


class Handler(http.server.BaseHTTPRequestHandler):
    def send(self, code, body=None, headers=()):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")

    def do_GET(self):
        host = self.headers.get("Host", "").split(":")[0]
        if self.path in ("/health", "/api/v1/health"):
            return self.send(200, {"status": "ok"})
        if self.path == "/users/42":
            return self.send(200, {"id": 42}) if self.authed() else self.send(401, {"error": "no token"})
        if self.path == "/page":
            html = b"<html><head><title>Hello</title></head><body>v1.2.3</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Set-Cookie", "session=abc; Secure; HttpOnly")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            return self.wfile.write(html)
        if self.path == "/" and host == "example.com":
            return self.send(200, {}, [("Strict-Transport-Security", "max-age=63072000"), ("X-Frame-Options", "DENY")])
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/login":
            b = self.body()
            if b.get("username") == "test-user" and b.get("password") == "s3cret":
                return self.send(200, {"access_token": TOKEN, "user": {"id": 42}})
            return self.send(401, {"error": "bad credentials"})
        if self.path == "/users":
            if not self.authed():
                return self.send(401, {"error": "no token"})
            b = self.body()
            return self.send(201, {"id": 42, "name": b.get("name"), "roles": ["user"]}, [("Location", "/users/42")])
        self.send(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path == "/users/42" and self.authed():
            return self.send(204)
        self.send(401, {"error": "no token"})

    def log_message(self, *args):
        pass


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 443), Handler)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
