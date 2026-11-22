"""PH parser backend — stdlib-only Python, zero dependencies.

Why stdlib instead of FastAPI: the deploy target is a free Cloady
container next to the user's Xray service. Zero dependencies means no
pip install step, no build failures, ~60 MB RAM, and it runs on any
Python 3.11+ host (Cloady / Render / any VPS) with a single command:
`PORT=8080 python3 server.py`.

Endpoints (all JSON, CORS open for the app):
  GET /health                      -> {"ok": true, ...}
  GET /api/home?page=1             -> most-viewed this week (Webmasters)
  GET /api/search?q=...&page=1     -> Webmasters search, 30/page
  GET /api/categories              -> Webmasters category list
  GET /api/category?id=37&page=1   -> videos in one category (site list)
  GET /api/video?viewkey=...       -> metadata + playable HLS sources
  GET /api/video_by_id?id=...     -> metadata only

Media (thumbs, m3u8, .ts segments) is NEVER proxied through here: the app
loads it straight from phncdn.com. This backend only moves kilobytes of
JSON per request, which is why the Cloady free tier's 10 GB/month traffic
and 4 CPU-hours/month are plenty for personal use.

Signed HLS URLs expire 2h after issue; the app fetches /api/video fresh
on every play, never caches URLs across launches.
"""

import json
import os
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ph_parse

# Tiny TTL cache for detail pages only: reopening the same video within
# 2 minutes reuses the (still valid, 2h) signed URLs instead of
# re-fetching the 1.6 MB detail page. Search/home are never cached.
_CACHE_TTL = 120
_cache = {}  # viewkey -> (timestamp, payload)


def _cached_video(viewkey):
    now = time.time()
    hit = _cache.get(viewkey)
    if hit and now - hit[0] < _CACHE_TTL:
        return hit[1]
    payload = ph_parse.video_sources(viewkey)
    try:
        payload["meta"] = ph_parse.video_by_id(viewkey)
    except Exception:
        payload["meta"] = None
    _cache[viewkey] = (now, payload)
    return payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep stdout clean-ish
        print(f"[{time.strftime('%H:%M:%S')}] {self.address_string()} {fmt % args}")

    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _query(self):
        parsed = urllib.parse.urlparse(self.path)
        return parsed.path, urllib.parse.parse_qs(parsed.query)

    def _int(self, qs, name, default):
        try:
            return max(1, int(qs.get(name, [default])[0]))
        except (TypeError, ValueError):
            return default

    def do_GET(self):
        path, qs = self._query()
        try:
            if path == "/health":
                self._send(200, {"ok": True, "service": "ph-parser", "time": int(time.time())})
            elif path == "/api/home":
                page = self._int(qs, "page", 1)
                self._send(200, ph_parse.search("", page, "mostviewed", "weekly"))
            elif path == "/api/search":
                q = qs.get("q", [""])[0]
                page = self._int(qs, "page", 1)
                ordering = qs.get("ordering", ["mostviewed"])[0]
                period = qs.get("period", ["weekly"])[0]
                self._send(200, ph_parse.search(q, page, ordering, period))
            elif path == "/api/categories":
                self._send(200, ph_parse.categories())
            elif path == "/api/category":
                cid = qs.get("id", [""])[0]
                if not cid:
                    self._send(400, {"error": "missing id"})
                    return
                page = self._int(qs, "page", 1)
                self._send(200, ph_parse.category_videos(cid, page))
            elif path == "/api/video_by_id":
                viewkey = qs.get("id", [""])[0]
                if not viewkey:
                    self._send(400, {"error": "missing id"})
                    return
                self._send(200, ph_parse.video_by_id(viewkey))
            elif path == "/api/video":
                viewkey = qs.get("viewkey", [""])[0] or qs.get("url", [""])[0]
                if "view_video.php" in viewkey:
                    viewkey = urllib.parse.parse_qs(
                        urllib.parse.urlparse(viewkey).query
                    ).get("viewkey", [""])[0]
                if not viewkey:
                    self._send(400, {"error": "missing viewkey"})
                    return
                self._send(200, _cached_video(viewkey))
            else:
                self._send(404, {"error": "not found", "path": path})
        except ph_parse.ParseError as exc:
            self._send(502, {"error": f"parse failed: {exc}"})
        except Exception as exc:  # noqa: BLE001 - surface as 502, keep serving
            self._send(502, {"error": f"upstream error: {exc}"})

    def do_OPTIONS(self):  # CORS preflight
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"ph-parser listening on 0.0.0.0:{port} (stdlib-only, no deps)")
    server.serve_forever()
