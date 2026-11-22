"""Pornhub parsing — isolated module.

Only this file talks to pornhub.com. When Pornhub changes its pages, only
this file (and the matching Dart port in app/lib/ph_parse.dart) needs to
change; the HTTP layer (server.py) and the app stay untouched.

Verified live 2026-11-22 from this VM (see ../README.md for evidence):
- Webmasters search: GET https://www.pornhub.com/webmasters/search
  -> 200, {"videos": [30 items]} with title/duration/views/rating/tags/
  categories/thumbs/page URL, but NO playable URL. Used for list/search.
- Detail page: GET https://www.pornhub.com/view_video.php?viewkey=<id>
  with a browser User-Agent -> 200, ~1.6 MB HTML containing
  `var flashvars_<id> = {...}` whose "mediaDefinitions" holds the playable
  URLs: 240/480/720/1080 HLS master.m3u8 on ev-h.phncdn.com, plus one mp4
  entry pointing at /video/get_media which currently returns [] (dead).
  Signed HLS URLs are valid 2h (validto-validfrom = 7200s).
- The same signed HLS URL fetched over IPv4 and IPv6 (two different source
  IPs) both returned 200, and with no Referer/Origin headers at all — so
  the URLs are NOT bound to the requesting IP. A backend may therefore
  issue them and the phone can play them. (Final proof still needs a phone
  playback test; the app falls back to in-app parsing if backend URLs fail.)
- Old tutorials are DEAD: a plain curl without a browser UA used to get a
  702 KB page with no flashvars/mediaDefinitions. A browser UA is required.

Logic here is our own implementation, written from the observed page
structure. yt-dlp's Pornhub extractor was used only as a reference for
the chain shape (age cookie / Origin+Referer on /video/get_media);
no yt-dlp code is vendored, and the `phub` library (AGPLv3) is NOT used.
"""

import json
import re
import time
import urllib.parse
import urllib.request

BASE = "https://www.pornhub.com"

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)

# Age cookies: Pornhub sets these after the age gate. Sending them up front
# keeps age-gated videos reachable without an interactive gate step.
# (Cookie names match yt-dlp's _set_age_cookies, used as reference only.)
DEFAULT_HEADERS = {
    "User-Agent": UA,
    "Cookie": (
        "age_verified=1; accessAgeDisclaimerPH=1; "
        "accessAgeDisclaimerUK=1; accessPH=1"
    ),
}

TIMEOUT = 30


class ParseError(Exception):
    """Pornhub answered, but not in the shape we expect (page changed?)."""


def _get(url, extra_headers=None):
    headers = dict(DEFAULT_HEADERS)
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.status, resp.read()


def _get_json(url, extra_headers=None):
    status, body = _get(url, extra_headers)
    if status != 200:
        raise ParseError(f"HTTP {status} from {url}")
    try:
        return json.loads(body.decode("utf-8"))
    except Exception as exc:
        raise ParseError(f"bad JSON from {url}: {exc}") from exc


def _clean_video(v):
    """Normalize one Webmasters video dict to the app's VideoItem shape."""
    return {
        "viewkey": v.get("video_id", ""),
        "title": v.get("title", ""),
        "duration": v.get("duration", ""),
        "views": v.get("views", 0),
        "rating": v.get("rating", 0),
        "thumb": v.get("thumb", "") or v.get("default_thumb", ""),
        "url": v.get("url", ""),
        "publish_date": v.get("publish_date", ""),
        "tags": [t.get("tag_name", "") for t in v.get("tags", [])],
        "categories": [c.get("category", "") for c in v.get("categories", [])],
        "pornstars": [p.get("pornstar_name", "") for p in v.get("pornstars", [])],
    }


def search(query="", page=1, ordering="mostviewed", period="weekly"):
    """Webmasters search. Empty query + ordering=mostviewed is the Home feed.

    ordering: mostviewed | toprated | longest | mostrecent
    period: weekly | monthly | alltime (only used with mostviewed/toprated)
    Returns {"videos": [VideoItem...], "page": n}.
    """
    params = {"page": page}
    if query:
        params["search"] = query
    if ordering:
        params["ordering"] = ordering
    if period:
        params["period"] = period
    url = BASE + "/webmasters/search?" + urllib.parse.urlencode(params)
    data = _get_json(url)
    videos = data.get("videos", [])
    return {"videos": [_clean_video(v) for v in videos], "page": page}


def categories():
    """Webmasters category list. Returns {"categories": [{id, category}]}."""
    return _get_json(BASE + "/webmasters/categories")


def video_by_id(viewkey):
    """Webmasters detail for one video (metadata only, no playable URL)."""
    url = BASE + "/webmasters/video_by_id?" + urllib.parse.urlencode(
        {"id": viewkey}
    )
    data = _get_json(url)
    video = data.get("video")
    if not video:
        raise ParseError(f"no video in video_by_id for {viewkey}")
    return _clean_video(video)


def _extract_flashvars(html):
    """Find `var flashvars_<n> = {...};` and parse the {...} with a
    balanced-brace scan (regex alone breaks: the JSON contains nested
    objects and '}' inside strings is rare but braces nest deeply)."""
    marker = html.find("var flashvars_")
    if marker < 0:
        raise ParseError("flashvars block not found in detail page")
    start = html.find("{", marker)
    if start < 0:
        raise ParseError("flashvars object not found")
    depth = 0
    in_str = False
    esc = False
    i = start
    while i < len(html):
        ch = html[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
        i += 1
    if depth != 0:
        raise ParseError("unterminated flashvars object")
    try:
        return json.loads(html[start : i + 1])
    except Exception as exc:
        raise ParseError(f"flashvars JSON unparsable: {exc}") from exc


def _verify_hls(url, viewkey):
    """GET the HLS master playlist (~235 bytes). Returns True only if the
    CDN answers 200 with a real playlist. This is the gate that keeps dead
    URLs out of the API response (see video_sources for why it exists)."""
    headers = dict(DEFAULT_HEADERS)
    headers["Origin"] = BASE
    headers["Referer"] = BASE + "/view_video.php?viewkey=" + viewkey
    try:
        req = urllib.request.Request(url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read(1024)
            return resp.status == 200 and b"#EXTM3U" in body
    except Exception:
        return False


def _fetch_sources_once(viewkey):
    """One detail-page fetch -> (flashvars, sources list). Raises ParseError
    if the page is not in the expected shape."""
    url = BASE + "/view_video.php?viewkey=" + urllib.parse.quote(viewkey)
    status, body = _get(url)
    if status != 200:
        raise ParseError(f"detail page HTTP {status} for {viewkey}")
    html = body.decode("utf-8", errors="ignore")
    flashvars = _extract_flashvars(html)
    defs = flashvars.get("mediaDefinitions") or []
    if not defs:
        raise ParseError("mediaDefinitions empty — page layout changed?")
    sources = []
    for d in defs:
        video_url = d.get("videoUrl", "")
        if not video_url:
            continue
        sources.append(
            {
                "quality": str(d.get("quality", "")),
                "format": d.get("format", ""),
                "url": video_url,
                "width": d.get("width", 0),
                "height": d.get("height", 0),
                "default": bool(d.get("defaultQuality", False)),
            }
        )
    return flashvars, sources


def video_sources(viewkey, max_attempts=5):
    """Fetch the detail page and return playable sources.

    Returns {"viewkey", "title", "duration", "thumb", "sources": [...]} where
    each source is {"quality", "format", "url", "width", "height",
    "default": bool}. HLS (m3u8) entries are the working route; the mp4
    /video/get_media entry currently returns [] and is kept only if
    Pornhub ever serves it again.

    RETRY BEHAVIOUR (found 2026-11-22, verified live): Pornhub randomly
    serves one of two HLS URL schemes for the same video, roughly 50/50:
    - ev-h.phncdn.com ... ?validfrom=&validto=&hash=  -> master.m3u8 200.
    - hv-h.phncdn.com ... ?h=<token>&e=<exp>&f=1     -> master.m3u8 410 Gone
      under every header combination tried (curl/HTTP2, full browser
      headers incl. Origin+Referer, session cookies). Possibly the new
      scheme needs a real browser's TLS fingerprint or a JS-set cookie;
      it may still play in ExoPlayer on a phone — unproven, so v1 treats
      it as dead. Each attempt re-fetches the detail page until the top
      HLS URL verifies with a real playlist GET (only ~235 bytes).
      5 attempts ~= 97% success at 50% per attempt.
    """
    last_error = None
    for attempt in range(1, max_attempts + 1):
        try:
            flashvars, sources = _fetch_sources_once(viewkey)
        except ParseError as exc:
            last_error = exc
            if attempt < max_attempts:
                time.sleep(1.0)
                continue
            raise
        sources.sort(
            key=lambda s: (
                0 if s["format"] == "hls" else 1,
                -(s["height"] or 0),
            )
        )
        hls = [s for s in sources if s["format"] == "hls"]
        if hls and _verify_hls(hls[0]["url"], viewkey):
            return {
                "viewkey": viewkey,
                "title": flashvars.get("video_title", ""),
                "duration": flashvars.get("video_duration", 0),
                "thumb": flashvars.get("image_url", ""),
                "sources": sources,
            }
        last_error = ParseError(
            f"attempt {attempt}: HLS URL did not verify "
            f"(host={hls[0]['url'].split('/')[2] if hls else 'none'})"
        )
        if attempt < max_attempts:
            time.sleep(1.5)
    raise ParseError(
        f"no verifiable HLS URL after {max_attempts} attempts: {last_error}"
    )
