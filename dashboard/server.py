"""Loopback-only HTTP surface. Browser controls use a per-process request token."""
import json
from pathlib import Path
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from .core import WorkspaceError
from .bridge import BridgeError

STATIC = Path(__file__).parent / "static"


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, workspace):
        if address[0] != "127.0.0.1":
            raise ValueError("The terminal workspace only listens on 127.0.0.1")
        super().__init__(address, Handler)
        self.workspace = workspace
        self.token = secrets.token_urlsafe(32)
        self.origin = f"http://127.0.0.1:{self.server_port}"
        self.stopping = threading.Event()

    def poll(self):
        while not self.stopping.is_set():
            self.workspace.refresh(force=True)
            self.stopping.wait(5)


class Handler(BaseHTTPRequestHandler):
    server_version = "TermDashboard/1"

    def log_message(self, *args):
        pass  # Never log terminal content, prompts, or handoff credentials.

    def respond(self, status, data, content_type="application/json; charset=utf-8"):
        payload = json.dumps(data).encode() if not isinstance(data, bytes) else data
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def allowed(self, api=False):
        if self.headers.get("Host") != self.server.origin.removeprefix("http://"):
            self.respond(403, {"error": "Use the local dashboard address."})
            return False
        origin = self.headers.get("Origin")
        if origin and origin != self.server.origin:
            self.respond(403, {"error": "Cross-origin requests are not allowed."})
            return False
        if api and not secrets.compare_digest(self.headers.get("X-TD-Token", ""), self.server.token):
            self.respond(403, {"error": "Reload the dashboard to reconnect."})
            return False
        return True

    def do_GET(self):
        path = urlsplit(self.path).path
        if not self.allowed(api=path.startswith("/api/")):
            return
        try:
            if path == "/health":
                return self.respond(200, {"app": "term-dashboard", "demo": self.server.workspace.bridge.demo})
            if path == "/api/state":
                return self.respond(200, self.server.workspace.view())
            if path == "/api/guide":
                return self.respond(200, self.server.workspace.guide())
            filename = {"/": "index.html", "/app.js": "app.js", "/style.css": "style.css", "/favicon.svg": "favicon.svg"}.get(path)
            if not filename:
                return self.respond(404, {"error": "Not found"})
            payload = (STATIC / filename).read_bytes()
            if filename == "index.html":
                payload = payload.replace(b"__TD_TOKEN__", self.server.token.encode())
            kind = {".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml"}[Path(filename).suffix]
            self.respond(200, payload, kind + "; charset=utf-8")
        except (WorkspaceError, BridgeError) as exc:
            self.respond(400, {"error": str(exc)})
        except Exception:
            self.respond(500, {"error": "The workspace could not complete this request. Try refreshing."})

    def do_POST(self):
        if not self.allowed(api=True):
            return
        if self.headers.get_content_type() != "application/json":
            return self.respond(415, {"error": "Send application/json."})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 24000:
                return self.respond(413, {"error": "Request must contain 1–24000 bytes."})
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise WorkspaceError("Expected a JSON object.")
            path = urlsplit(self.path).path
            work = self.server.workspace
            if path == "/api/refresh":
                work.refresh(force=True)
                result = {"message": "Sessions refreshed."}
            elif path == "/api/controller":
                result = work.configure_controller(body.get("session"), body.get("enabled"))
            elif path == "/api/session":
                result = work.session_action(body.get("session"), body.get("action"))
            elif path == "/api/note":
                result = work.note(body.get("session"), body.get("action"))
            elif path == "/api/proposal":
                result = work.resolve_proposal(body.get("id"), body.get("action"))
            elif path == "/api/awake":
                result = work.awake(body.get("duration"))
            elif path == "/api/demo":
                result = work.demo_loop()
            else:
                return self.respond(404, {"error": "Not found"})
            self.respond(200, result)
        except (WorkspaceError, BridgeError, ValueError, TypeError) as exc:
            self.respond(400, {"error": str(exc)})
        except Exception:
            self.respond(500, {"error": "The action could not be confirmed. Refresh before trying again."})

    def do_OPTIONS(self):
        self.respond(403, {"error": "Cross-origin access is not allowed."})
