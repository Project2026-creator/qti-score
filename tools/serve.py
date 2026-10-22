"""Serve only the workbench's public assets on the local loopback interface."""
import http.server
from pathlib import Path
import socketserver
import urllib.parse


WEB_FILES = frozenset([
    "index.html", "style.css", "app.mjs", "batch.mjs", "composite.mjs",
    "gap.mjs", "hottext.mjs", "inline-choice.mjs", "match.mjs", "order.mjs",
    "slider.mjs", "qti-score.mjs", "workspace.mjs", "results.mjs",
])
PACKAGE_FILES = frozenset([
    "sample-package.zip", "order-package.zip", "match-package.zip", "gap-package.zip",
    "hottext-package.zip", "inline-choice-package.zip", "slider-package.zip",
    "composite-package.zip", "composite-tolerance-package.zip", "composite-inline-package.zip",
    "composite-fallback-package.zip",
])


def public_asset(path):
    if path in ("/README.md", "/LICENSE", "/NOTICE", "/web", "/web/"):
        return True
    parts = path.split("/")
    if len(parts) != 3 or parts[0] != "":
        return False
    folder, name = parts[1:]
    if not name or name.startswith(".") or "\\" in path or "\x00" in path or ":" in name:
        return False
    if folder == "web":
        return name in WEB_FILES or name in PACKAGE_FILES
    if folder == "sdk":
        return name in ("index.mjs", "qti-core.mjs", "index.d.mts", "README.md")
    if folder == "examples":
        return Path(name).suffix in (".xml", ".json", ".jsonl", ".mjs", ".txt")
    return False


class DevelopmentHandler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        # Conditional requests must not combine a rebuilt core with cached SDK
        # modules. Apply the same policy to GET and HEAD.
        for name in ("If-Modified-Since", "If-None-Match"):
            if name in self.headers:
                del self.headers[name]
        try:
            request = urllib.parse.urlsplit(self.path)
            path = urllib.parse.unquote(request.path, errors="strict")
            if request.scheme or request.netloc:
                raise ValueError("origin-relative requests only")
            if path == "/":
                self.send_response(302)
                self.send_header("Location", "/web/")
                self.end_headers()
                return None
            if not public_asset(path):
                raise ValueError("not a public asset")
            root = Path(self.directory).resolve()
            relative = path.lstrip("/").rstrip("/")
            target = (root / relative).resolve()
            if target.relative_to(root).as_posix() != relative:
                raise ValueError("asset redirects outside its public path")
            if path in ("/web", "/web/"):
                entry = (target / "index.html").resolve()
                if entry.relative_to(root).as_posix() != "web/index.html" or not entry.is_file():
                    raise ValueError("no workbench entry point")
            elif not target.is_file():
                raise ValueError("no public file")
        except (ValueError, OSError, RuntimeError):
            self.send_error(404, "Not found")
            return None
        return super().send_head()

    def list_directory(self, path):
        self.send_error(404, "Not found")
        return None

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()


class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # Avoid localized reverse-DNS failures on older Windows Python.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]
