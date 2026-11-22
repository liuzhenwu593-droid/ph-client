"""Live test for the backend: boots server.py on a scratch port and hits
every endpoint against the real pornhub.com. Run: python3 test_backend.py

Checks: /health, /api/search (30 videos), /api/home, /api/categories,
/api/video (sources include HLS m3u8, and the first HLS URL itself
fetches HTTP 200 — end-to-end playable proof). No mocks: if Pornhub
changes, this test is supposed to go red.
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWKEY = "68e2bb7570170"  # first result of the 2026-11-22 verification search


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def get(base, path):
    req = urllib.request.Request(base + path, headers={"User-Agent": "test"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"HTTP {exc.code} on {path}: {body[:500]}") from exc


def main():
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    proc = subprocess.Popen(
        [sys.executable, "server.py"],
        cwd=HERE,
        env={**os.environ, "PORT": str(port)},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    failures = []
    try:
        deadline = time.time() + 15
        up = False
        while time.time() < deadline:
            try:
                status, _ = get(base, "/health")
                if status == 200:
                    up = True
                    break
            except Exception:
                time.sleep(0.5)
        if not up:
            print("FAIL: server did not come up")
            return 1

        def check(name, cond, extra=""):
            print(("PASS " if cond else "FAIL ") + name + (f" — {extra}" if extra else ""))
            if not cond:
                failures.append(name)

        status, health = get(base, "/health")
        check("health", status == 200 and health.get("ok") is True, str(health))

        status, search = get(base, "/api/search?q=test&page=1")
        vids = search.get("videos", [])
        check("search 200 + 30 videos", status == 200 and len(vids) == 30, f"got {len(vids)}")
        v0 = vids[0] if vids else {}
        check(
            "search item shape",
            all(k in v0 for k in ("viewkey", "title", "duration", "views", "thumb", "url")),
            str(list(v0.keys())),
        )

        status, home = get(base, "/api/home?page=1")
        check("home 200 + videos", status == 200 and len(home.get("videos", [])) > 0,
              f"got {len(home.get('videos', []))}")

        status, cats = get(base, "/api/categories")
        check("categories 200", status == 200 and len(cats.get("categories", [])) > 50,
              f"got {len(cats.get('categories', []))}")

        status, video = get(base, f"/api/video?viewkey={VIEWKEY}")
        sources = video.get("sources", [])
        check("video 200 + sources", status == 200 and len(sources) >= 4,
              f"got {len(sources)} sources")
        hls = [s for s in sources if s.get("format") == "hls"]
        check("HLS sources present", len(hls) >= 4, f"hls={len(hls)}")
        check("qualities 240/480/720/1080",
              {"240", "480", "720", "1080"} <= {s.get("quality") for s in hls},
              str(sorted({s.get("quality") for s in hls})))

        if hls:
            req = urllib.request.Request(hls[0]["url"], headers={"User-Agent": "test"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8", errors="ignore")
            check("first HLS master.m3u8 fetches 200 + playlist",
                  resp.status == 200 and "#EXTM3U" in body and "index-v1-a1.m3u8" in body,
                  f"status={resp.status} len={len(body)}")

        status, meta = get(base, f"/api/video_by_id?id={VIEWKEY}")
        check("video_by_id 200", status == 200 and meta.get("viewkey") == VIEWKEY,
              str(meta.get("title", ""))[:60])

        print()
        if failures:
            print(f"RESULT: {len(failures)} FAILURES: {failures}")
            return 1
        print("RESULT: ALL PASS")
        return 0
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            out, _ = proc.communicate(timeout=5)
            if failures:
                print("--- server log ---")
                print(out[-3000:])
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
