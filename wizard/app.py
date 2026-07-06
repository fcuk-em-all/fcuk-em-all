# wizard/app.py - FCUK-EM-ALL Control Plane FastAPI layer.
# Phase 1 (/api/health,stats,system,recent,me + SPA) UNCHANGED.
# Phase 2 adds VAULT search fan-out + DISCOVER public-domain browse/queue.
# All upstream credentials from env (never hardcoded, never logged). Upstream
# failure degrades to OFFLINE / null / omitted - never a 500. External DISCOVER
# calls are serialized + rate-limited + IPv4-forced. Downloads are single-threaded.
import asyncio
import hashlib
import logging
import os
import re
import secrets
import time
import time as _time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import urlparse, quote, unquote
import json

import httpx
import psutil
from argon2 import PasswordHasher
from argon2.low_level import Type as _ArgonType
from fastapi import FastAPI, Request, BackgroundTasks, Body
from fastapi.responses import JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


JELLYFIN_URL = _env("JELLYFIN_URL", "http://jellyfin:8096")
JELLYFIN_API_KEY = _env("JELLYFIN_API_KEY")
NAVIDROME_URL = _env("NAVIDROME_URL", "http://navidrome:4533")
NAVIDROME_USER = _env("NAVIDROME_USER", "admin")
NAVIDROME_PASS = _env("NAVIDROME_PASS")
KAVITA_URL = _env("KAVITA_URL", "http://kavita:5000")
KAVITA_USER = _env("KAVITA_USER", "admin")
KAVITA_PASS = _env("KAVITA_PASS")
ABS_URL = _env("ABS_URL", "http://audiobookshelf:13378")
JELLYSEERR_URL = _env("JELLYSEERR_URL", "http://jellyseerr:5055")
ABS_TOKEN = _env("ABS_TOKEN")
IMMICH_URL = _env("IMMICH_URL", "http://immich:2283")
IMMICH_API_KEY = _env("IMMICH_API_KEY")

# public deep-link bases (through Caddy), derived from the appliance domain
BASE_DOMAIN = _env("SF_BASE_DOMAIN", "fcuk-em-all.com")
JELLYFIN_WEB = f"https://jellyfin.{BASE_DOMAIN}"
NAVIDROME_WEB = f"https://navidrome.{BASE_DOMAIN}"
KAVITA_WEB = f"https://kavita.{BASE_DOMAIN}"
ABS_WEB = f"https://audiobookshelf.{BASE_DOMAIN}"
IMMICH_WEB = f"https://immich.{BASE_DOMAIN}"

_DIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dist")

# ---- Phase 2 constants ----
_UA = f"fcuk-em-all-wizard/2.0 (+https://{BASE_DOMAIN})"
_DZ_ROOT = "/srv/media/dropzone"
_DZ_SHARES = ["media", "music", "books", "audiobooks", "photos"]
_DROPZONE = {"film": "media", "music": "music", "book": "books", "audio": "audiobooks"}
_KNOWN_EXTS = {".mp4", ".mkv", ".avi", ".mpeg", ".mpg", ".ogv", ".mov", ".webm",
               ".mp3", ".m4a", ".flac", ".ogg", ".wav", ".opus", ".epub", ".pdf", ".zip"}
_DEFAULT_EXT = {"film": ".mp4", "music": ".mp3", "book": ".epub", "audio": ".zip"}

# ---- logging (stdout + best-effort importer log) ----
logging.basicConfig(level=logging.INFO, format="%(asctime)s [wizard] %(levelname)s %(message)s")
_log = logging.getLogger("wizard")
try:
    _imp_dir = "/srv/media/.importer"
    if os.path.isdir(_imp_dir) and os.access(_imp_dir, os.W_OK):
        _fh = logging.FileHandler(os.path.join(_imp_dir, "importer.log"))
        _fh.setFormatter(logging.Formatter("%(asctime)s [wizard-queue] %(levelname)s %(message)s"))
        _log.addHandler(_fh)
except Exception:
    pass

_client: Optional[httpx.AsyncClient] = None
_ext_client: Optional[httpx.AsyncClient] = None
_kavita_jwt: Optional[str] = None
_kavita_lock = asyncio.Lock()

# external rate-limit (serialize all external calls; per-host min spacing)
_ext_lock = asyncio.Lock()
_ext_last: dict = {}
# single-threaded download queue
_download_lock = asyncio.Lock()
_active_downloads: set = set()
_active_lock = asyncio.Lock()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global _client, _ext_client
    _client = httpx.AsyncClient(timeout=httpx.Timeout(10.0, connect=3.0))
    # dedicated external client: IPv4-forced (local_address 0.0.0.0), UA, follow redirects
    _ext_client = httpx.AsyncClient(
        timeout=httpx.Timeout(60.0, connect=10.0),
        headers={"User-Agent": _UA},
        transport=httpx.AsyncHTTPTransport(local_address="0.0.0.0"),
        follow_redirects=True,
    )
    try:
        await _kavita_login()
    except Exception:
        pass
    yield
    for c in (_client, _ext_client):
        if c is not None:
            await c.aclose()


app = FastAPI(title="FCUK-EM-ALL Control Plane", lifespan=lifespan)


# ---------------- helpers (Phase 1) ----------------
def _subsonic_qs() -> str:
    salt = secrets.token_hex(8)
    token = hashlib.md5((NAVIDROME_PASS + salt).encode()).hexdigest()
    return f"u={NAVIDROME_USER}&t={token}&s={salt}&v=1.16.1&c=fcuk-em-all&f=json"


def _abs_headers() -> dict:
    return {"Authorization": f"Bearer {ABS_TOKEN}"}


def _immich_headers() -> dict:
    return {"x-api-key": IMMICH_API_KEY}


def _jf_headers() -> dict:
    return {"X-Emby-Token": JELLYFIN_API_KEY}


async def _kavita_login() -> str:
    global _kavita_jwt
    async with _kavita_lock:
        r = await _client.post(
            f"{KAVITA_URL}/api/Account/login",
            json={"username": KAVITA_USER, "password": KAVITA_PASS},
        )
        r.raise_for_status()
        _kavita_jwt = r.json().get("token")
        return _kavita_jwt


async def _kavita_request(method: str, path: str, **kw) -> httpx.Response:
    global _kavita_jwt
    if not _kavita_jwt:
        await _kavita_login()
    headers = {"Authorization": f"Bearer {_kavita_jwt}"}
    r = await _client.request(method, f"{KAVITA_URL}{path}", headers=headers, **kw)
    if r.status_code == 401:
        await _kavita_login()
        headers = {"Authorization": f"Bearer {_kavita_jwt}"}
        r = await _client.request(method, f"{KAVITA_URL}{path}", headers=headers, **kw)
    return r


def _iso_from_ms(ms) -> str:
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).isoformat()


def _epoch(iso: str) -> float:
    if not iso:
        return 0.0
    s = iso.strip().replace("Z", "+00:00")
    if "." in s:
        head, _, tail = s.partition(".")
        frac = ""
        rest = ""
        for i, ch in enumerate(tail):
            if ch.isdigit():
                frac += ch
            else:
                rest = tail[i:]
                break
        s = f"{head}.{frac[:6]}{rest}"
    try:
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return 0.0


# ---------------- health (Phase 1) ----------------
async def _ping(url: str) -> bool:
    try:
        r = await _client.get(url, timeout=3.0)
        return r.status_code == 200
    except Exception:
        return False


async def _ping_navidrome() -> bool:
    try:
        r = await _client.get(f"{NAVIDROME_URL}/rest/ping.view?{_subsonic_qs()}", timeout=3.0)
        if r.status_code != 200:
            return False
        return r.json().get("subsonic-response", {}).get("status") == "ok"
    except Exception:
        return False


async def _ping_kavita() -> bool:
    try:
        if not _kavita_jwt:
            try:
                await _kavita_login()
            except Exception:
                pass
        r = await _client.get(f"{KAVITA_URL}/api/health", timeout=3.0)
        return r.status_code == 200
    except Exception:
        return False


@app.get("/api/health")
async def api_health():
    jf, nd, kv, ab, im, js = await asyncio.gather(
        _ping(f"{JELLYFIN_URL}/health"),
        _ping_navidrome(),
        _ping_kavita(),
        _ping(f"{ABS_URL}/ping"),
        _ping(f"{IMMICH_URL}/api/server/ping"),
        _ping(f"{JELLYSEERR_URL}/api/v1/status"),
    )
    return {
        "jellyfin": "ONLINE" if jf else "OFFLINE",
        "navidrome": "ONLINE" if nd else "OFFLINE",
        "kavita": "ONLINE" if kv else "OFFLINE",
        "audiobookshelf": "ONLINE" if ab else "OFFLINE",
        "immich": "ONLINE" if im else "OFFLINE",
        "jellyseerr": "ONLINE" if js else "OFFLINE",
    }


# ---------------- stats (Phase 1) ----------------
async def _films() -> Optional[int]:
    r = await _client.get(f"{JELLYFIN_URL}/Items/Counts", headers=_jf_headers())
    r.raise_for_status()
    return r.json().get("MovieCount")


async def _albums() -> Optional[int]:
    total = 0
    offset = 0
    while True:
        r = await _client.get(
            f"{NAVIDROME_URL}/rest/getAlbumList2.view?type=alphabeticalByName&size=500&offset={offset}&{_subsonic_qs()}"
        )
        r.raise_for_status()
        albums = r.json().get("subsonic-response", {}).get("albumList2", {}).get("album", [])
        total += len(albums)
        if len(albums) < 500:
            break
        offset += 500
    return total


async def _books() -> Optional[int]:
    r = await _kavita_request("GET", "/api/Stats/server/stats")
    r.raise_for_status()
    return r.json().get("seriesCount")


async def _abs_book_library() -> Optional[dict]:
    r = await _client.get(f"{ABS_URL}/api/libraries", headers=_abs_headers())
    r.raise_for_status()
    libs = r.json().get("libraries", [])
    book = next((l for l in libs if l.get("mediaType") == "book"), None)
    return book or (libs[0] if libs else None)


async def _audiobooks() -> Optional[int]:
    lib = await _abs_book_library()
    if not lib:
        return None
    r = await _client.get(
        f"{ABS_URL}/api/libraries/{lib['id']}/items?limit=1", headers=_abs_headers()
    )
    r.raise_for_status()
    return r.json().get("total")


async def _photos() -> Optional[int]:
    r = await _client.get(f"{IMMICH_URL}/api/server/statistics", headers=_immich_headers())
    r.raise_for_status()
    return r.json().get("photos")


@app.get("/api/stats")
async def api_stats():
    async def safe(coro):
        try:
            return await coro
        except Exception:
            return None

    films, albums, books, audiobooks, photos = await asyncio.gather(
        safe(_films()), safe(_albums()), safe(_books()), safe(_audiobooks()), safe(_photos())
    )
    return {
        "films": films,
        "albums": albums,
        "books": books,
        "audiobooks": audiobooks,
        "photos": photos,
    }


# ---------------- system (Phase 1) ----------------
@app.get("/api/system")
def api_system():
    cpu = psutil.cpu_percent(interval=0.2)
    vm = psutil.virtual_memory()
    try:
        du = psutil.disk_usage("/srv/media")
    except Exception:
        du = psutil.disk_usage("/")
    return {
        "cpu_pct": round(cpu, 1),
        "ram_pct": round(vm.percent, 1),
        "disk_used_bytes": int(du.used),
        "disk_total_bytes": int(du.total),
        "disk_pct": round(du.percent, 1),
        "uptime_seconds": int(time.time() - psutil.boot_time()),
    }


# ---------------- recent (Phase 1) ----------------
async def _recent_jellyfin() -> list:
    r = await _client.get(
        f"{JELLYFIN_URL}/Items?SortBy=DateCreated&SortOrder=Descending&Limit=10"
        "&IncludeItemTypes=Movie,Series&Recursive=true&Fields=DateCreated",
        headers=_jf_headers(),
    )
    r.raise_for_status()
    out = []
    for it in r.json().get("Items", []):
        out.append({"type": "FILM", "title": it.get("Name", "?"), "added": it.get("DateCreated", "")})
    return out


async def _recent_navidrome() -> list:
    r = await _client.get(f"{NAVIDROME_URL}/rest/getAlbumList2.view?type=newest&size=10&{_subsonic_qs()}")
    r.raise_for_status()
    albums = r.json().get("subsonic-response", {}).get("albumList2", {}).get("album", [])
    out = []
    for a in albums:
        title = a.get("name", "?")
        artist = a.get("artist")
        if artist:
            title = f"{title} — {artist}"
        out.append({"type": "MUSIC", "title": title, "added": a.get("created", "")})
    return out


async def _recent_kavita() -> list:
    r = await _kavita_request("POST", "/api/Series/recently-added-v2", json={})
    r.raise_for_status()
    out = []
    data = r.json()
    if isinstance(data, list):
        for s in data[:10]:
            added = s.get("created") or s.get("lastChapterAddedUtc") or ""
            out.append({"type": "BOOK", "title": s.get("name", "?"), "added": added})
    return out


async def _recent_abs() -> list:
    lib = await _abs_book_library()
    if not lib:
        return []
    r = await _client.get(
        f"{ABS_URL}/api/libraries/{lib['id']}/items?limit=10&sort=addedAt&desc=1",
        headers=_abs_headers(),
    )
    r.raise_for_status()
    out = []
    for it in r.json().get("results", []):
        title = it.get("media", {}).get("metadata", {}).get("title", "?")
        added = it.get("addedAt")
        iso = _iso_from_ms(added) if isinstance(added, (int, float)) else ""
        out.append({"type": "AUDIO", "title": title, "added": iso})
    return out


async def _recent_immich() -> list:
    r = await _client.post(
        f"{IMMICH_URL}/api/search/metadata",
        headers=_immich_headers(),
        json={"size": 10, "order": "desc"},
    )
    r.raise_for_status()
    items = r.json().get("assets", {}).get("items", [])
    out = []
    for a in items:
        out.append({
            "type": "PHOTO",
            "title": a.get("originalFileName", "?"),
            "added": a.get("fileCreatedAt", ""),
        })
    return out


@app.get("/api/recent")
async def api_recent():
    async def safe(coro):
        try:
            return await coro
        except Exception:
            return []

    groups = await asyncio.gather(
        safe(_recent_jellyfin()),
        safe(_recent_navidrome()),
        safe(_recent_kavita()),
        safe(_recent_abs()),
        safe(_recent_immich()),
    )
    items = [it for group in groups for it in group]
    items.sort(key=lambda x: _epoch(x.get("added", "")), reverse=True)
    return items[:20]


# ---------------- me (Phase 1 + Phase 3 expansion) ----------------
def _is_admin_headers(request: Request) -> bool:
    groups = request.headers.get("Remote-Groups")
    if groups is None:
        return True  # test container (no Caddy header) -> treat as admin
    return "admins" in [g.strip() for g in groups.split(",") if g.strip()]


@app.get("/api/me")
def api_me(request: Request):
    user = request.headers.get("Remote-User") or request.headers.get("remote-user")
    username = user if user else "ADMIN"
    return {
        "username": username,
        "is_admin": _is_admin_headers(request),
        "must_change_password": _pending_reset_get(username),
    }


# ---------------- liveness (Phase 1) ----------------
@app.get("/health")
def health():
    return JSONResponse({"status": "ok"})


# ================================================================
# PHASE 2 - VAULT search fan-out
# ================================================================
async def _search_jellyfin(q: str) -> list:
    r = await _client.get(
        f"{JELLYFIN_URL}/Items?SearchTerm={quote(q)}&Recursive=true&Limit=20"
        "&IncludeItemTypes=Movie,Series&Fields=Name,Type,ProductionYear",
        headers=_jf_headers(),
    )
    r.raise_for_status()
    out = []
    for it in r.json().get("Items", []):
        year = it.get("ProductionYear")
        out.append({
            "type": "FILM",
            "title": it.get("Name", "?"),
            "subtitle": str(year) if year else "",
            "service": "JELLYFIN",
            "deep_link": f"{JELLYFIN_WEB}/web/index.html#!/details?id={it.get('Id')}",
        })
    return out


async def _search_navidrome(q: str) -> list:
    r = await _client.get(
        f"{NAVIDROME_URL}/rest/search3.view?query={quote(q)}&artistCount=0&albumCount=20&songCount=0&{_subsonic_qs()}"
    )
    r.raise_for_status()
    albums = r.json().get("subsonic-response", {}).get("searchResult3", {}).get("album", [])
    out = []
    for a in albums:
        out.append({
            "type": "MUSIC",
            "title": a.get("name", "?"),
            "subtitle": a.get("artist", ""),
            "service": "NAVIDROME",
            "deep_link": f"{NAVIDROME_WEB}/app/#/album/{a.get('id')}/show",
        })
    return out


async def _search_kavita(q: str) -> list:
    r = await _kavita_request("GET", f"/api/Search/search?queryString={quote(q)}")
    r.raise_for_status()
    out = []
    for s in r.json().get("series", []):
        yr = s.get("releaseYear")
        sub = s.get("libraryName", "") or ""
        if yr:
            sub = f"{sub} · {yr}" if sub else str(yr)
        out.append({
            "type": "BOOK",
            "title": s.get("name", "?"),
            "subtitle": sub,
            "service": "KAVITA",
            "deep_link": f"{KAVITA_WEB}/library/{s.get('libraryId')}/series/{s.get('seriesId')}",
        })
    return out


async def _search_abs(q: str) -> list:
    lib = await _abs_book_library()
    if not lib:
        return []
    r = await _client.get(
        f"{ABS_URL}/api/libraries/{lib['id']}/search?q={quote(q)}", headers=_abs_headers()
    )
    r.raise_for_status()
    out = []
    for entry in r.json().get("book", []):
        li = entry.get("libraryItem", {})
        md = li.get("media", {}).get("metadata", {})
        out.append({
            "type": "AUDIO",
            "title": md.get("title", "?"),
            "subtitle": md.get("authorName", "") or "",
            "service": "AUDIOBOOKSHELF",
            "deep_link": f"{ABS_WEB}/item/{li.get('id')}",
        })
    return out


async def _search_immich(q: str) -> list:
    r = await _client.post(
        f"{IMMICH_URL}/api/search/metadata", headers=_immich_headers(),
        json={"query": q, "size": 20},
    )
    r.raise_for_status()
    out = []
    for a in r.json().get("assets", {}).get("items", []):
        out.append({
            "type": "PHOTO",
            "title": a.get("originalFileName", "?"),
            "subtitle": (a.get("fileCreatedAt") or "")[:10],
            "service": "IMMICH",
            "deep_link": f"{IMMICH_WEB}/photos/{a.get('id')}",
        })
    return out


@app.get("/api/search")
async def api_search(q: str, type: str = "all"):
    q = (q or "").strip()
    if len(q) < 3:
        return JSONResponse({"error": "query too short (min 3 chars)", "query": q}, status_code=400)
    type = (type or "all").lower()

    async def wrap(coro):
        try:
            return (await coro, True)
        except Exception:
            return ([], False)

    groups = await asyncio.gather(
        wrap(_search_jellyfin(q)), wrap(_search_navidrome(q)), wrap(_search_kavita(q)),
        wrap(_search_abs(q)), wrap(_search_immich(q)),
    )
    results = []
    for items, _ok in groups:
        results.extend(items)
    responded = sum(1 for _items, ok in groups if ok)

    if type != "all":
        tmap = {"film": "FILM", "music": "MUSIC", "book": "BOOK", "audio": "AUDIO", "photo": "PHOTO"}
        want = tmap.get(type)
        results = [r for r in results if r["type"] == want]
    return {"results": results, "total": len(results), "query": q, "type": type, "responded": responded}


# ================================================================
# PHASE 2 - DISCOVER (external, serialized + rate-limited + IPv4)
# ================================================================
async def _ext_get(url: str, min_delay: float = 1.0, **kw) -> httpx.Response:
    host = urlparse(url).netloc
    async with _ext_lock:
        wait = min_delay - (_time.monotonic() - _ext_last.get(host, 0.0))
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            return await _ext_client.get(url, **kw)
        finally:
            _ext_last[host] = _time.monotonic()


def _short(q: str) -> bool:
    return len((q or "").strip()) < 3


@app.get("/api/discover/gutenberg")
async def discover_gutenberg(q: str):
    if _short(q):
        return JSONResponse({"error": "query too short"}, status_code=400)
    results = []
    try:
        r = await _ext_get(f"https://gutendex.com/books/?search={quote(q.strip())}", min_delay=1.0)
        if r.status_code == 200:
            for b in r.json().get("results", [])[:20]:
                epub = (b.get("formats") or {}).get("application/epub+zip")
                if not epub:
                    continue
                authors = b.get("authors") or []
                summ = b.get("summaries") or []
                results.append({
                    "id": str(b.get("id")),
                    "title": b.get("title"),
                    "author": authors[0]["name"] if authors else "Unknown",
                    "description": (summ[0][:280] if summ else ""),
                    "format": "EPUB",
                    "size_bytes": None,
                    "download_url": epub,
                })
    except Exception as exc:
        _log.error("discover gutenberg failed: %s", exc.__class__.__name__)
    return {"results": results, "source": "GUTENBERG"}


@app.get("/api/discover/librivox")
async def discover_librivox(q: str):
    if _short(q):
        return JSONResponse({"error": "query too short"}, status_code=400)
    results = []
    try:
        r = await _ext_get(
            f"https://librivox.org/api/feed/audiobooks/?title={quote(q.strip())}&format=json&limit=20",
            min_delay=1.0,
        )
        if r.status_code == 200:
            for b in r.json().get("books", []) or []:
                authors = b.get("authors") or []
                if authors:
                    a0 = authors[0]
                    author = f"{a0.get('first_name','')} {a0.get('last_name','')}".strip()
                else:
                    author = "Various"
                results.append({
                    "id": str(b.get("id")),
                    "title": b.get("title"),
                    "author": author or "Various",
                    "duration": b.get("totaltime"),
                    "chapters": b.get("num_sections"),
                    "download_url": b.get("url_zip_file"),
                })
    except Exception as exc:
        _log.error("discover librivox failed: %s", exc.__class__.__name__)
    return {"results": results, "source": "LIBRIVOX"}


@app.get("/api/discover/archive")
async def discover_archive(q: str, collection: str = "films"):
    if _short(q):
        return JSONResponse({"error": "query too short"}, status_code=400)
    q = q.strip()
    if collection == "great78":
        qq = f"collection:78rpm AND mediatype:audio AND ({q})"
        fmt = "MP3"
    else:
        collection = "films"
        qq = (f"mediatype:movies AND date:[1900-01-01 TO 1928-12-31] "
              f"AND licenseurl:(*publicdomain*) AND ({q})")
        fmt = "MP4"
    params = [("q", qq), ("fl[]", "identifier"), ("fl[]", "title"),
              ("fl[]", "creator"), ("fl[]", "date"), ("rows", "20"), ("output", "json")]
    results = []
    try:
        r = await _ext_get("https://archive.org/advancedsearch.php", min_delay=1.0, params=params)
        if r.status_code == 200:
            for d in r.json().get("response", {}).get("docs", []):
                ident = d.get("identifier")
                if not ident:
                    continue
                results.append({
                    "id": ident,
                    "title": d.get("title") or ident,
                    "creator": d.get("creator") or "",
                    "date": (d.get("date") or "")[:10],
                    "format": fmt,
                    # details page - the queue worker resolves the real file via metadata
                    "download_url": f"https://archive.org/details/{ident}",
                })
    except Exception as exc:
        _log.error("discover archive failed: %s", exc.__class__.__name__)
    return {"results": results, "source": "ARCHIVE", "collection": collection}


@app.get("/api/discover/loc")
async def discover_loc(q: str):
    if _short(q):
        return JSONResponse({"error": "query too short"}, status_code=400)
    results = []
    try:
        r = await _ext_get(f"https://www.loc.gov/search/?q={quote(q.strip())}&fo=json&c=20", min_delay=2.0)
        if r.status_code == 200:
            for it in r.json().get("results", [])[:20]:
                of = it.get("original_format")
                if isinstance(of, list):
                    of = of[0] if of else None
                landing = it.get("url") or it.get("id")
                results.append({
                    "id": str(it.get("id") or landing),
                    "title": it.get("title"),
                    "date": it.get("date"),
                    "format": of,
                    # LoC exposes landing pages only - never a fabricated download URL
                    "download_url": None,
                    "landing_url": landing,
                })
    except Exception as exc:
        _log.error("discover loc failed: %s", exc.__class__.__name__)
    return {"results": results, "source": "LOC"}


# ---------- Ep4 Pass 2: Wikimedia Commons / Open Library / Europeana ----------
_WM_UA = f"fcuk-em-all-wizard/2.0 (https://{BASE_DOMAIN})"


@app.get("/api/discover/wikimedia")
async def discover_wikimedia(q: str, type: str = "all"):
    if _short(q):
        return JSONResponse({"error": "query too short"}, status_code=400)
    q = q.strip()
    ftypes = []
    if type in ("audio", "all"):
        ftypes.append("audio")
    if type in ("video", "all"):
        ftypes.append("video")
    if not ftypes:
        ftypes = ["audio", "video"]
    results, seen = [], set()
    try:
        for ft in ftypes:
            params = {"action": "query", "generator": "search",
                      "gsrsearch": f"{q} filetype:{ft}", "gsrnamespace": "6", "gsrlimit": "15",
                      "prop": "imageinfo", "iiprop": "url|mediatype|size|mime", "format": "json"}
            r = await _ext_get("https://commons.wikimedia.org/w/api.php", min_delay=1.0,
                               headers={"User-Agent": _WM_UA}, params=params)
            if r.status_code != 200:
                continue
            pages = (r.json().get("query", {}) or {}).get("pages", {}) or {}
            for pid, pg in pages.items():
                ii = (pg.get("imageinfo") or [{}])[0]
                mt, dl = ii.get("mediatype"), ii.get("url")
                if mt not in ("AUDIO", "VIDEO") or not dl:
                    continue  # images and unresolved files filtered out
                key = str(pg.get("pageid") or pid)
                if key in seen:
                    continue
                seen.add(key)
                results.append({
                    "id": key, "title": (pg.get("title") or "").split(":", 1)[-1],
                    "description": "", "mediatype": mt, "mime": ii.get("mime"),
                    "size_bytes": ii.get("size"), "download_url": dl, "source": "WIKIMEDIA",
                })
    except Exception as exc:
        _log.error("discover wikimedia failed: %s", exc.__class__.__name__)
    return {"results": results, "source": "WIKIMEDIA"}


@app.get("/api/discover/openlibrary")
async def discover_openlibrary(q: str):
    if _short(q):
        return JSONResponse({"error": "query too short"}, status_code=400)
    results = []
    try:
        r = await _ext_get("https://openlibrary.org/search.json", min_delay=1.0,
                           params={"q": q.strip(), "limit": "12",
                                   "fields": "key,title,author_name,first_publish_year,ia,availability"})
        docs = r.json().get("docs", []) if r.status_code == 200 else []
        for d in docs:
            key = d.get("key") or ""
            authors = d.get("author_name") or []
            item = {
                "id": (key.split("/")[-1] or d.get("title") or "ol"),
                "title": d.get("title") or "?",
                "author": authors[0] if authors else "Unknown",
                "year": d.get("first_publish_year"),
                "format": None, "download_url": None,
                "landing_url": "https://openlibrary.org" + key, "source": "OPENLIBRARY",
            }
            ia = d.get("ia")
            ident = (ia[0] if isinstance(ia, list) else ia) if ia else None
            if ident:
                try:
                    mr = await _ext_get("https://archive.org/metadata/%s" % quote(ident), min_delay=1.0)
                    if mr.status_code == 200:
                        files = mr.json().get("files", []) or []
                        epub = next((f["name"] for f in files
                                     if f.get("format") == "EPUB" or (f.get("name") or "").lower().endswith(".epub")), None)
                        pdf = next((f["name"] for f in files
                                    if f.get("format") in ("Text PDF", "PDF") or (f.get("name") or "").lower().endswith(".pdf")), None)
                        chosen = epub or pdf
                        if chosen:
                            item["format"] = "EPUB" if chosen == epub else "PDF"
                            item["download_url"] = "https://archive.org/download/%s/%s" % (ident, quote(chosen))
                except Exception as exc:
                    _log.error("openlibrary IA check failed: %s", exc.__class__.__name__)
            results.append(item)
    except Exception as exc:
        _log.error("discover openlibrary failed: %s", exc.__class__.__name__)
    return {"results": results, "source": "OPENLIBRARY"}


@app.get("/api/discover/europeana")
async def discover_europeana(q: str):
    if _short(q):
        return JSONResponse({"error": "query too short"}, status_code=400)
    key = os.environ.get("EUROPEANA_API_KEY", "").strip()
    if not key:
        return JSONResponse({"error": "Europeana API key not configured (EUROPEANA_API_KEY missing)"}, status_code=500)
    results = []
    try:
        r = await _ext_get("https://api.europeana.eu/record/v2/search.json", min_delay=2.0,
                           params={"query": q.strip(), "media": "true", "reusability": "open",
                                   "rows": "15", "qf": "TYPE:SOUND OR TYPE:VIDEO", "wskey": key})
        if r.status_code == 200:
            for it in r.json().get("items", []) or []:
                typ = it.get("type")
                if typ not in ("SOUND", "VIDEO"):
                    continue
                title = it.get("title") or ["?"]
                creator = it.get("dcCreator") or []
                shown_by = it.get("edmIsShownBy") or []
                shown_at = it.get("edmIsShownAt") or []
                yr = it.get("year")
                if isinstance(yr, list):
                    yr = yr[0] if yr else None
                results.append({
                    "id": str(it.get("id") or it.get("guid") or title[0]),
                    "title": title[0], "creator": creator[0] if creator else None,
                    "year": yr, "type": typ,
                    "download_url": shown_by[0] if shown_by else None,
                    "landing_url": shown_at[0] if shown_at else (it.get("guid") or ""),
                    "source": "EUROPEANA",
                })
    except Exception as exc:
        _log.error("discover europeana failed: %s", exc.__class__.__name__)
    return {"results": results, "source": "EUROPEANA"}


# ---------------- queue (download into importer dropzones) ----------------
def _sanitize_name(name: str) -> str:
    name = re.sub(r"[^A-Za-z0-9 ._-]", "_", (name or "").strip())
    return (name or "download")[:120]


def _pick_archive_file(files: list, media_type: Optional[str]) -> Optional[str]:
    if media_type == "music":
        prefs = ["VBR MP3", "MP3", "128Kbps MP3", "64Kbps MP3", "h.264", "MPEG4"]
        exts = (".mp3", ".flac", ".ogg", ".m4a", ".mp4")
    else:
        prefs = ["h.264", "MPEG4", "512Kb MPEG4", "h.264 IA", "Ogg Video", "MPEG2"]
        exts = (".mp4", ".ogv", ".mpeg", ".mpg", ".avi", ".mkv")
    for pf in prefs:
        for f in files:
            if f.get("format") == pf and f.get("name"):
                return f["name"]
    for f in files:
        n = (f.get("name") or "").lower()
        if n.endswith(exts):
            return f["name"]
    return None


async def _resolve_download(url: str, media_type: str):
    # returns (real_url, suggested_name). Resolves archive.org details pages via metadata.
    if "archive.org/details/" in url:
        ident = url.split("/details/")[-1].strip("/").split("/")[0].split("?")[0]
        r = await _ext_get(f"https://archive.org/metadata/{ident}", min_delay=1.0)
        r.raise_for_status()
        files = r.json().get("files", [])
        chosen = _pick_archive_file(files, media_type)
        if not chosen:
            raise RuntimeError(f"no downloadable file for archive item {ident}")
        return (f"https://archive.org/download/{ident}/{quote(chosen)}", chosen)
    return (url, None)


# ---- Phase 3 polish: download progress (state/wizard/download_progress.json) ----
# STATE_DIR is defined later in the file (Phase 3 block); resolve it at call time.
_dl_progress_lock = asyncio.Lock()


def _dl_progress_file():
    return os.path.join(STATE_DIR, "download_progress.json")


def _dl_progress_load():
    try:
        with open(_dl_progress_file()) as _f:
            _d = json.load(_f)
            return _d if isinstance(_d, dict) else {}
    except Exception:
        return {}


def _dl_progress_prune(d):
    now = time.time()
    for k in list(d.keys()):
        e = d.get(k) or {}
        if e.get("status") in ("complete", "error") and now - e.get("terminal_at", now) > 60:
            d.pop(k, None)
    return d


def _dl_entry(item_id, title, received, total_bytes, status):
    pct = int(received * 100 / total_bytes) if total_bytes else None
    e = {"item_id": item_id, "title": title, "bytes_received": received,
         "total_bytes": total_bytes, "pct": pct, "status": status}
    if status == "complete" and total_bytes:
        e["pct"] = 100
    if status in ("complete", "error"):
        e["terminal_at"] = time.time()
    return e


async def _dl_progress_set(item_id, entry):
    async with _dl_progress_lock:
        d = _dl_progress_load()
        d[item_id] = entry
        _dl_progress_prune(d)
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            p = _dl_progress_file()
            tmp = p + ".tmp"
            with open(tmp, "w") as _f:
                json.dump(d, _f)
            os.replace(tmp, p)
        except Exception as exc:
            _log.error("download_progress write failed: %s", exc.__class__.__name__)


async def _download_worker(item_id: str, title: str, url: str, media_type: str):
    part = None
    total = 0
    total_bytes = None
    try:
        async with _download_lock:  # single-threaded: one download at a time
            dz = _DROPZONE.get(media_type, "media")
            dest_dir = os.path.join(_DZ_ROOT, dz)
            real_url, suggested = await _resolve_download(url, media_type)
            ext = os.path.splitext(urlparse(real_url).path)[1].lower()
            if ext not in _KNOWN_EXTS:
                sug_ext = os.path.splitext(suggested)[1].lower() if suggested else ""
                ext = sug_ext if sug_ext in _KNOWN_EXTS else _DEFAULT_EXT.get(media_type, ".bin")
            fname = _sanitize_name(title) + ext
            dest = os.path.join(dest_dir, fname)
            part = dest + ".part"
            h = hashlib.sha256()
            _log.info("queue download start: %r -> %s", title, dest)
            async with _ext_client.stream("GET", real_url) as resp:
                resp.raise_for_status()
                _cl = resp.headers.get("content-length")
                total_bytes = int(_cl) if _cl and _cl.isdigit() else None
                await _dl_progress_set(item_id, _dl_entry(item_id, title, 0, total_bytes, "downloading"))
                last_report = 0.0
                last_pct = -5
                with open(part, "wb") as fh:
                    async for chunk in resp.aiter_bytes(65536):
                        fh.write(chunk)
                        h.update(chunk)
                        total += len(chunk)
                        if total_bytes:
                            pct = int(total * 100 / total_bytes)
                            if pct >= last_pct + 5:
                                last_pct = pct
                                await _dl_progress_set(item_id, _dl_entry(item_id, title, total, total_bytes, "downloading"))
                        else:
                            now = time.time()
                            if now - last_report >= 10:
                                last_report = now
                                await _dl_progress_set(item_id, _dl_entry(item_id, title, total, total_bytes, "downloading"))
            os.replace(part, dest)
            part = None
            await _dl_progress_set(item_id, _dl_entry(item_id, title, total, total_bytes, "complete"))
            _log.info("queue download done: %s bytes=%d sha256=%s", fname, total, h.hexdigest())
    except Exception as exc:
        _log.error("queue download FAILED: %r (%s)", title, exc.__class__.__name__)
        try:
            await _dl_progress_set(item_id, _dl_entry(item_id, title, total, total_bytes, "error"))
        except Exception:
            pass
        if part:
            try:
                os.remove(part)
            except OSError:
                pass
    finally:
        async with _active_lock:
            _active_downloads.discard(item_id)


@app.post("/api/queue")
async def api_queue(background: BackgroundTasks, payload: dict = Body(...)):
    source = payload.get("source")
    item_id = payload.get("item_id")
    title = payload.get("title") or "download"
    url = payload.get("download_url")
    media_type = payload.get("media_type")
    if not url or not isinstance(url, str) or not url.startswith(("http://", "https://")):
        return JSONResponse({"error": "invalid or missing download_url"}, status_code=400)
    if media_type not in _DROPZONE:
        return JSONResponse({"error": "invalid media_type"}, status_code=400)
    if not item_id:
        return JSONResponse({"error": "missing item_id"}, status_code=400)
    dedup_key = f"{source}:{item_id}"
    async with _active_lock:
        if dedup_key in _active_downloads:
            return {"status": "ALREADY_QUEUED", "item_id": item_id, "title": title}
        _active_downloads.add(dedup_key)
    background.add_task(_download_worker, dedup_key, title, url, media_type)
    return {"status": "QUEUED", "item_id": item_id, "title": title}


@app.get("/api/queue/progress")
def api_queue_progress():
    d = _dl_progress_load()
    _dl_progress_prune(d)
    return {"items": list(d.values())}


@app.get("/api/queue/status")
def api_queue_status():
    active = []
    for share in _DZ_SHARES:
        path = os.path.join(_DZ_ROOT, share, ".importer-status")
        try:
            with open(path) as fh:
                line = fh.readline().strip()
        except Exception:
            continue
        if not line:
            continue
        low = line.lower()
        if low.startswith("processing:"):
            active.append({"share": share, "file": line.split(":", 1)[1].strip(),
                           "status": "PROCESSING", "progress": ""})
        elif low.startswith("scanning"):
            active.append({"share": share, "file": "", "status": "SCANNING", "progress": ""})
    try:
        writable = os.access(os.path.join(_DZ_ROOT, "books"), os.W_OK)
    except Exception:
        writable = False
    return {"active": active, "importer_writable": writable}


# ================================================================
# PHASE 3 - USERS (Authelia users_database.yml + 5-app propagation)
# ================================================================
USERS_DB = os.environ.get("USERS_DB_PATH", "/app/authelia/users_database.yml")
STATE_DIR = os.environ.get("WIZARD_STATE_DIR", "/app/state/wizard")
PENDING_RESET = os.path.join(STATE_DIR, "pending_reset.json")
USERSDB_BACKUP_DIR = os.path.join(STATE_DIR, "usersdb_backups")

_ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16, type=_ArgonType.ID)
USERNAME_RE = re.compile(r"^[A-Za-z0-9_-]{3,32}$")
_usersdb_lock = asyncio.Lock()
_navidrome_native_token = None


def _now_stamp():
    return time.strftime("%Y%m%d%H%M%S", time.gmtime())


def _argon_hash(pw):
    return _ph.hash(pw)


def _argon_verify(hash_str, pw):
    try:
        return _ph.verify(hash_str, pw)
    except Exception:
        return False


# ---- pending_reset.json (never raises) ----
def _pending_reset_load():
    try:
        with open(PENDING_RESET) as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _pending_reset_get(username):
    return _pending_reset_load().get(username) is True


def _pending_reset_set(username, value):
    d = _pending_reset_load()
    if value:
        d[username] = True
    else:
        d.pop(username, None)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = PENDING_RESET + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=2)
        os.replace(tmp, PENDING_RESET)
    except Exception as exc:
        _log.error("pending_reset write failed: %s", exc.__class__.__name__)


# ---- users_database.yml text-block manager (admin byte-for-byte safe) ----
def _usersdb_read():
    with open(USERS_DB) as f:
        return f.read()


def _usersdb_split(text):
    lines = text.splitlines(keepends=True)
    idx = None
    for i, ln in enumerate(lines):
        if re.match(r"^users:\s*$", ln):
            idx = i
            break
    if idx is None:
        raise RuntimeError("users_database.yml has no 'users:' key")
    prefix = "".join(lines[: idx + 1])
    order = []
    blocks = {}
    cur = None
    for ln in lines[idx + 1:]:
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", ln)
        if m:
            cur = m.group(1)
            order.append(cur)
            blocks[cur] = ln
        elif cur is not None:
            blocks[cur] += ln
    return prefix, order, blocks


def _usersdb_assemble(prefix, order, blocks):
    return prefix + "".join(blocks[u] for u in order)


def _yaml_squote(s):
    return "'" + str(s).replace("'", "''") + "'"


def _block_field(block, field):
    m = re.search(r"^    %s:\s*(.*)$" % re.escape(field), block, re.M)
    if not m:
        return ""
    v = m.group(1).strip()
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        v = v[1:-1].replace("''", "'")
    return v


def _block_groups(block):
    groups = []
    in_g = False
    for ln in block.splitlines():
        if re.match(r"^    groups:\s*$", ln):
            in_g = True
            continue
        if in_g:
            m = re.match(r"^      -\s*(\S+)\s*$", ln)
            if m:
                groups.append(m.group(1))
            elif ln.strip():
                break
    return groups


def _parse_users(text):
    _prefix, order, blocks = _usersdb_split(text)
    out = []
    for u in order:
        b = blocks[u]
        out.append({
            "username": u,
            "displayname": _block_field(b, "displayname"),
            "email": _block_field(b, "email"),
            "groups": _block_groups(b),
            "disabled": _block_field(b, "disabled").lower() == "true",
        })
    return out


def _user_block(username, displayname, email, pw_hash, is_admin):
    groups = ["admins"] if is_admin else ["users"]
    b = "  %s:\n" % username
    b += "    disabled: false\n"
    b += "    displayname: %s\n" % _yaml_squote(displayname or username)
    b += "    password: %s\n" % _yaml_squote(pw_hash)
    b += "    email: %s\n" % _yaml_squote(email or (username + "@fcuk-em-all.local"))
    b += "    groups:\n"
    for g in groups:
        b += "      - %s\n" % g
    return b


async def _usersdb_apply(mutate):
    # Read -> backup -> mutate -> assert admin byte-identical + >=1 admin -> in-place write
    # -> re-read verify admin present -> sleep for Authelia watch reload.
    async with _usersdb_lock:
        original = _usersdb_read()
        prefix, order, blocks = _usersdb_split(original)
        if "admin" not in blocks:
            raise RuntimeError("admin entry missing before write - abort")
        admin_before = blocks["admin"]
        try:
            os.makedirs(USERSDB_BACKUP_DIR, exist_ok=True)
            with open(os.path.join(USERSDB_BACKUP_DIR, "users_database.yml." + _now_stamp()), "w") as f:
                f.write(original)
        except Exception as exc:
            _log.error("usersdb backup failed: %s", exc.__class__.__name__)
        mutate(order, blocks)
        if "admin" not in blocks or blocks["admin"] != admin_before:
            raise RuntimeError("admin block would change - abort, no write")
        if sum(1 for u in order if "admins" in _block_groups(blocks[u])) < 1:
            raise RuntimeError("would leave zero admins - abort")
        new_text = _usersdb_assemble(prefix, order, blocks)
        with open(USERS_DB, "w") as f:  # IN-PLACE (same inode) for Authelia :ro mount + watch
            f.write(new_text)
        after = _usersdb_read()
        _p2, _o2, b2 = _usersdb_split(after)
        if "admin" not in b2 or b2["admin"] != admin_before:
            with open(USERS_DB, "w") as f:
                f.write(original)
            raise RuntimeError("post-write admin verify failed - restored")
        await asyncio.sleep(1.5)  # Authelia file-watch reload


# ---- Navidrome native token (separate from Subsonic) ----
async def _navidrome_login():
    global _navidrome_native_token
    r = await _client.post(f"{NAVIDROME_URL}/auth/login", json={"username": NAVIDROME_USER, "password": NAVIDROME_PASS})
    r.raise_for_status()
    _navidrome_native_token = r.json().get("token")
    return _navidrome_native_token


async def _navidrome_req(method, path, **kw):
    global _navidrome_native_token
    if not _navidrome_native_token:
        await _navidrome_login()
    headers = kw.pop("headers", {})
    headers["x-nd-authorization"] = f"Bearer {_navidrome_native_token}"
    r = await _client.request(method, f"{NAVIDROME_URL}{path}", headers=headers, **kw)
    if r.status_code == 401:
        await _navidrome_login()
        headers["x-nd-authorization"] = f"Bearer {_navidrome_native_token}"
        r = await _client.request(method, f"{NAVIDROME_URL}{path}", headers=headers, **kw)
    return r


# ---- 5-app propagation (each op -> list of (service, ok, detail)) ----
async def _prop_create(username, displayname, email, password, is_admin):
    email = email or (username + "@fcuk-em-all.local")
    res = []
    try:
        cr = await _client.post(f"{JELLYFIN_URL}/Users/New", headers=_jf_headers(), json={"Name": username, "Password": password})
        cr.raise_for_status()
        jid = cr.json().get("Id")
        if is_admin and jid:
            await _client.post(f"{JELLYFIN_URL}/Users/{jid}/Policy", headers=_jf_headers(), json={"IsAdministrator": True})
        res.append(("jellyfin", True, "created"))
    except Exception as exc:
        res.append(("jellyfin", False, exc.__class__.__name__))
    try:
        r = await _navidrome_req("POST", "/api/user", json={"userName": username, "name": displayname or username, "password": password, "isAdmin": bool(is_admin)})
        r.raise_for_status()
        res.append(("navidrome", True, "created"))
    except Exception as exc:
        res.append(("navidrome", False, exc.__class__.__name__))
    try:
        roles = ["Admin", "Login"] if is_admin else ["Login"]
        inv = await _kavita_request("POST", "/api/Account/invite", json={"email": email, "roles": roles, "libraries": [], "ageRestriction": {"ageRating": 0, "includeUnknowns": True}})
        inv.raise_for_status()
        m = re.search(r"token=([^&]+)", inv.json().get("emailLink", ""))
        if not m:
            raise RuntimeError("no invite token")
        conf = await _client.post(f"{KAVITA_URL}/api/Account/confirm-email", json={"email": email, "username": username, "password": password, "token": unquote(m.group(1))})
        conf.raise_for_status()
        res.append(("kavita", True, "created"))
    except Exception as exc:
        res.append(("kavita", False, exc.__class__.__name__))
    try:
        r = await _client.post(f"{ABS_URL}/api/users", headers=_abs_headers(), json={"username": username, "password": password, "type": "admin" if is_admin else "user"})
        r.raise_for_status()
        res.append(("audiobookshelf", True, "created"))
    except Exception as exc:
        res.append(("audiobookshelf", False, exc.__class__.__name__))
    try:
        cr = await _client.post(f"{IMMICH_URL}/api/admin/users", headers=_immich_headers(), json={"email": email, "password": password, "name": displayname or username})
        cr.raise_for_status()
        iid = cr.json().get("id")
        if is_admin and iid:
            await _client.put(f"{IMMICH_URL}/api/admin/users/{iid}", headers=_immich_headers(), json={"isAdmin": True})
        res.append(("immich", True, "created"))
    except Exception as exc:
        res.append(("immich", False, exc.__class__.__name__))
    # Ep4 Pass4b: arr-stack admin tools have NO multi-user provisioning API (qBittorrent is
    # single-admin; Radarr/Sonarr/Prowlarr are single-user). For admins they are surfaced as
    # N/A (ok=None) - never attempted, never for non-admins (server-side is_admin gate here).
    if is_admin:
        for _svc in ("qbittorrent", "prowlarr", "radarr", "sonarr"):
            res.append((_svc, None, "N/A - single-user admin tool, no per-user account"))
    return res


async def _prop_delete(username, email):
    email = email or (username + "@fcuk-em-all.local")
    res = []
    try:
        r = await _client.get(f"{JELLYFIN_URL}/Users", headers=_jf_headers())
        r.raise_for_status()
        jid = next((u["Id"] for u in r.json() if u.get("Name") == username), None)
        if jid:
            (await _client.delete(f"{JELLYFIN_URL}/Users/{jid}", headers=_jf_headers())).raise_for_status()
        res.append(("jellyfin", True, "deleted" if jid else "absent"))
    except Exception as exc:
        res.append(("jellyfin", False, exc.__class__.__name__))
    try:
        r = await _navidrome_req("GET", "/api/user")
        r.raise_for_status()
        nid = next((u["id"] for u in r.json() if u.get("userName") == username), None)
        if nid:
            (await _navidrome_req("DELETE", f"/api/user/{nid}")).raise_for_status()
        res.append(("navidrome", True, "deleted" if nid else "absent"))
    except Exception as exc:
        res.append(("navidrome", False, exc.__class__.__name__))
    try:
        d = await _kavita_request("DELETE", f"/api/Users/delete-user?username={quote(username)}")
        d.raise_for_status()
        res.append(("kavita", True, "deleted"))
    except Exception as exc:
        res.append(("kavita", False, exc.__class__.__name__))
    try:
        r = await _client.get(f"{ABS_URL}/api/users", headers=_abs_headers())
        r.raise_for_status()
        aid = next((u["id"] for u in r.json().get("users", []) if u.get("username") == username), None)
        if aid:
            (await _client.delete(f"{ABS_URL}/api/users/{aid}", headers=_abs_headers())).raise_for_status()
        res.append(("audiobookshelf", True, "deleted" if aid else "absent"))
    except Exception as exc:
        res.append(("audiobookshelf", False, exc.__class__.__name__))
    try:
        r = await _client.get(f"{IMMICH_URL}/api/admin/users", headers=_immich_headers())
        r.raise_for_status()
        iid = next((u["id"] for u in r.json() if u.get("email") == email), None)
        if iid:
            (await _client.request("DELETE", f"{IMMICH_URL}/api/admin/users/{iid}", headers=_immich_headers(), json={"force": True})).raise_for_status()
        res.append(("immich", True, "deleted" if iid else "absent"))
    except Exception as exc:
        res.append(("immich", False, exc.__class__.__name__))
    return res


async def _prop_password(username, email, new_password):
    email = email or (username + "@fcuk-em-all.local")
    res = []
    try:
        r = await _client.get(f"{JELLYFIN_URL}/Users", headers=_jf_headers())
        r.raise_for_status()
        jid = next((u["Id"] for u in r.json() if u.get("Name") == username), None)
        if jid:
            await _client.post(f"{JELLYFIN_URL}/Users/{jid}/Password", headers=_jf_headers(), json={"ResetPassword": True})
            (await _client.post(f"{JELLYFIN_URL}/Users/{jid}/Password", headers=_jf_headers(), json={"NewPw": new_password})).raise_for_status()
        res.append(("jellyfin", bool(jid), "set" if jid else "absent"))
    except Exception as exc:
        res.append(("jellyfin", False, exc.__class__.__name__))
    try:
        r = await _navidrome_req("GET", "/api/user")
        r.raise_for_status()
        u = next((x for x in r.json() if x.get("userName") == username), None)
        if u:
            body = {"id": u["id"], "userName": u["userName"], "name": u.get("name", username), "password": new_password, "isAdmin": u.get("isAdmin", False)}
            (await _navidrome_req("PUT", f"/api/user/{u['id']}", json=body)).raise_for_status()
        res.append(("navidrome", bool(u), "set" if u else "absent"))
    except Exception as exc:
        res.append(("navidrome", False, exc.__class__.__name__))
    try:
        (await _kavita_request("POST", "/api/Account/reset-password", json={"userName": username, "password": new_password, "oldPassword": ""})).raise_for_status()
        res.append(("kavita", True, "set"))
    except Exception as exc:
        res.append(("kavita", False, exc.__class__.__name__))
    try:
        r = await _client.get(f"{ABS_URL}/api/users", headers=_abs_headers())
        r.raise_for_status()
        aid = next((u["id"] for u in r.json().get("users", []) if u.get("username") == username), None)
        if aid:
            (await _client.patch(f"{ABS_URL}/api/users/{aid}", headers=_abs_headers(), json={"password": new_password})).raise_for_status()
        res.append(("audiobookshelf", bool(aid), "set" if aid else "absent"))
    except Exception as exc:
        res.append(("audiobookshelf", False, exc.__class__.__name__))
    try:
        r = await _client.get(f"{IMMICH_URL}/api/admin/users", headers=_immich_headers())
        r.raise_for_status()
        iid = next((u["id"] for u in r.json() if u.get("email") == email), None)
        if iid:
            (await _client.put(f"{IMMICH_URL}/api/admin/users/{iid}", headers=_immich_headers(), json={"password": new_password})).raise_for_status()
        res.append(("immich", bool(iid), "set" if iid else "absent"))
    except Exception as exc:
        res.append(("immich", False, exc.__class__.__name__))
    return res


def _report(results):
    return [{"service": s, "ok": ok, "detail": d} for s, ok, d in results]


# ---- endpoints ----
_app_presence_cache = {"at": 0.0, "data": None}


async def _app_presence():
    # Cached (30s) identifier sets present in each of the five apps. Each value is a
    # set (present ids) or None if that app's list call failed. Never raises.
    now = time.time()
    cached = _app_presence_cache["data"]
    if cached is not None and now - _app_presence_cache["at"] < 30:
        return cached

    async def jf():
        r = await _client.get(f"{JELLYFIN_URL}/Users", headers=_jf_headers()); r.raise_for_status()
        return {u.get("Name") for u in r.json()}

    async def nd():
        r = await _navidrome_req("GET", "/api/user"); r.raise_for_status()
        return {u.get("userName") for u in r.json()}

    async def kv():
        r = await _kavita_request("GET", "/api/Users"); r.raise_for_status()
        return {u.get("username") for u in r.json()}

    async def ab():
        r = await _client.get(f"{ABS_URL}/api/users", headers=_abs_headers()); r.raise_for_status()
        return {u.get("username") for u in r.json().get("users", [])}

    async def im():
        r = await _client.get(f"{IMMICH_URL}/api/admin/users", headers=_immich_headers()); r.raise_for_status()
        return {u.get("email") for u in r.json()}

    async def safe(coro):
        try:
            return await coro
        except Exception:
            return None

    jset, nset, kset, aset, iset = await asyncio.gather(safe(jf()), safe(nd()), safe(kv()), safe(ab()), safe(im()))
    data = {"jellyfin": jset, "navidrome": nset, "kavita": kset, "abs": aset, "immich": iset}
    _app_presence_cache["at"] = now
    _app_presence_cache["data"] = data
    return data


@app.get("/api/users")
async def api_users_list(request: Request):
    if not _is_admin_headers(request):
        return JSONResponse({"error": "admin only"}, status_code=403)
    try:
        users = _parse_users(_usersdb_read())
    except Exception:
        return JSONResponse({"error": "users db unavailable"}, status_code=500)
    # admin is always all-true without API calls; only fetch presence if non-admins exist
    presence = await _app_presence() if any(u["username"] != "admin" for u in users) else None
    for u in users:
        u["must_change_password"] = _pending_reset_get(u["username"])
        u["undeletable"] = (u["username"] == "admin")
        if u["username"] == "admin":
            u["app_access"] = {k: True for k in ("jellyfin", "navidrome", "kavita", "abs", "immich")}
        else:
            ident = {"jellyfin": u["username"], "navidrome": u["username"], "kavita": u["username"],
                     "abs": u["username"], "immich": u["email"] or (u["username"] + "@fcuk-em-all.local")}
            acc = {}
            for app in ("jellyfin", "navidrome", "kavita", "abs", "immich"):
                s = presence.get(app) if presence else None
                acc[app] = (ident[app] in s) if s is not None else None
            u["app_access"] = acc
    return {"users": users}


@app.post("/api/users")
async def api_users_create(request: Request, payload: dict = Body(...)):
    if not _is_admin_headers(request):
        return JSONResponse({"error": "admin only"}, status_code=403)
    username = (payload.get("username") or "").strip()
    displayname = (payload.get("displayname") or username).strip()
    email = (payload.get("email") or "").strip()
    password = payload.get("password") or ""
    is_admin = bool(payload.get("is_admin"))
    if not USERNAME_RE.match(username):
        return JSONResponse({"error": "username must be 3-32 chars: letters, digits, underscore, hyphen"}, status_code=400)
    if username == "admin":
        return JSONResponse({"error": "username 'admin' is reserved"}, status_code=400)
    if len(password) < 12:
        return JSONResponse({"error": "password must be at least 12 characters"}, status_code=400)
    if username in {u["username"] for u in _parse_users(_usersdb_read())}:
        return JSONResponse({"error": "username already exists"}, status_code=400)
    pw_hash = _argon_hash(password)

    def mut(order, blocks):
        blocks[username] = _user_block(username, displayname, email, pw_hash, is_admin)
        if username not in order:
            order.append(username)

    try:
        await _usersdb_apply(mut)
    except Exception as exc:
        _log.error("usersdb create failed: %s", exc.__class__.__name__)
        return JSONResponse({"error": "failed to write users database"}, status_code=500)
    _pending_reset_set(username, True)
    report = _report(await _prop_create(username, displayname, email, password, is_admin))
    status = 200 if all(r["ok"] for r in report) else 207
    return JSONResponse({"username": username, "authelia": "created", "propagation": report, "must_change_password": True}, status_code=status)


@app.delete("/api/users/{username}")
async def api_users_delete(username: str, request: Request):
    if not _is_admin_headers(request):
        return JSONResponse({"error": "admin only"}, status_code=403)
    if username == "admin":
        return JSONResponse({"error": "Cannot delete the built-in admin account"}, status_code=400)
    users = {u["username"]: u for u in _parse_users(_usersdb_read())}
    if username not in users:
        return JSONResponse({"error": "user not found"}, status_code=404)
    target = users[username]
    if "admins" in target["groups"] and sum(1 for u in users.values() if "admins" in u["groups"]) <= 1:
        return JSONResponse({"error": "Cannot delete the last administrator"}, status_code=400)
    email = target["email"]

    def mut(order, blocks):
        blocks.pop(username, None)
        if username in order:
            order.remove(username)

    try:
        await _usersdb_apply(mut)
    except Exception as exc:
        _log.error("usersdb delete failed: %s", exc.__class__.__name__)
        return JSONResponse({"error": "failed to write users database"}, status_code=500)
    _pending_reset_set(username, False)
    report = _report(await _prop_delete(username, email))
    status = 200 if all(r["ok"] for r in report) else 207
    return JSONResponse({"username": username, "authelia": "deleted", "propagation": report}, status_code=status)


@app.post("/api/users/{username}/change-password")
async def api_users_change_password(username: str, request: Request, payload: dict = Body(...)):
    caller = request.headers.get("Remote-User") or "ADMIN"
    is_admin = _is_admin_headers(request)
    if username == "admin":
        return JSONResponse({"error": "The built-in admin account cannot be modified in this pass"}, status_code=400)
    if not is_admin and caller != username:
        return JSONResponse({"error": "forbidden"}, status_code=403)
    new_password = payload.get("new_password") or ""
    if len(new_password) < 12:
        return JSONResponse({"error": "new password must be at least 12 characters"}, status_code=400)
    users = {u["username"]: u for u in _parse_users(_usersdb_read())}
    if username not in users:
        return JSONResponse({"error": "user not found"}, status_code=404)
    if not is_admin:
        _p, _o, blocks = _usersdb_split(_usersdb_read())
        if not _argon_verify(_block_field(blocks.get(username, ""), "password"), payload.get("current_password") or ""):
            return JSONResponse({"error": "current password is incorrect"}, status_code=400)
    pw_hash = _argon_hash(new_password)

    def mut(order, blocks):
        b = blocks.get(username)
        if b is None:
            raise RuntimeError("user vanished")
        blocks[username] = re.sub(r"^(    password: ).*$", lambda mm: mm.group(1) + _yaml_squote(pw_hash), b, count=1, flags=re.M)

    try:
        await _usersdb_apply(mut)
    except Exception as exc:
        _log.error("usersdb change-password failed: %s", exc.__class__.__name__)
        return JSONResponse({"error": "failed to write users database"}, status_code=500)
    _pending_reset_set(username, False)
    report = _report(await _prop_password(username, users[username]["email"], new_password))
    status = 200 if all(r["ok"] for r in report) else 207
    return JSONResponse({"username": username, "authelia": "updated", "propagation": report, "must_change_password": False}, status_code=status)


# ================================================================
# FIRST-RUN SETUP (gate + /api/setup/*) - MUST be registered before the
# /api/{rest:path} 404 and the SPA catch-all below.
# ================================================================
import base64 as _b64
import hmac as _hmac
import hashlib as _hashlib
import struct as _struct
import secrets as _pysecrets

SETUP_COMPLETE_FILE = os.path.join(STATE_DIR, "setup_complete")
CONFIG_PATH = os.environ.get("WIZARD_CONFIG_PATH", "/app/config.json")
_SETUP_MIN_FREE_GB = 50
_SETUP_WARN_FREE_GB = 100
_SETUP_MODULES = ("core", "arr", "vpn")


def _setup_complete() -> bool:
    return os.path.isfile(SETUP_COMPLETE_FILE)


def _setup_guard():
    """Return a 403 response if setup is already complete, else None."""
    if _setup_complete():
        return JSONResponse({"error": "setup already complete"}, status_code=403)
    return None


def _config_load() -> dict:
    try:
        with open(CONFIG_PATH) as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _config_merge(patch: dict):
    cfg = _config_load()
    cfg.update(patch)
    os.makedirs(os.path.dirname(CONFIG_PATH) or ".", exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, CONFIG_PATH)


def _totp_secret() -> str:
    return _b64.b32encode(_pysecrets.token_bytes(20)).decode().rstrip("=")


def _totp_ok(secret_b32: str, code: str, window: int = 1) -> bool:
    try:
        key = _b64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8), casefold=True)
    except Exception:
        return False
    code = (code or "").strip().replace(" ", "")
    if not (code.isdigit() and len(code) == 6):
        return False
    counter = int(time.time()) // 30
    for off in range(-window, window + 1):
        msg = _struct.pack(">Q", counter + off)
        h = _hmac.new(key, msg, _hashlib.sha1).digest()
        o = h[-1] & 0x0F
        val = (_struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000
        if f"{val:06d}" == code:
            return True
    return False


@app.middleware("http")
async def _setup_gate(request: Request, call_next):
    """Before setup completes, only /api/setup/*, /api/health and the SPA are
    reachable; all other /api data routes return 403 so the normal app cannot
    be used until the wizard has run."""
    p = request.url.path
    if p.startswith("/api/") and not p.startswith("/api/setup/") and p != "/api/health":
        if not _setup_complete():
            return JSONResponse({"error": "setup required", "setup_required": True}, status_code=403)
    return await call_next(request)


@app.get("/api/setup/status")
def setup_status():
    return {"complete": _setup_complete()}


@app.post("/api/setup/validate-storage")
def setup_validate_storage(payload: dict = Body(...)):
    g = _setup_guard()
    if g:
        return g
    path = (payload.get("path") or "").strip()
    if not path:
        return JSONResponse({"ok": False, "error": "path required"}, status_code=400)
    probe = path
    while probe and not os.path.exists(probe):
        parent = os.path.dirname(probe.rstrip("/"))
        if parent == probe:
            break
        probe = parent
    if not probe or not os.path.isdir(probe):
        return JSONResponse({"ok": False, "error": f"no existing directory found for {path}"}, status_code=400)
    writable = os.access(probe, os.W_OK)
    try:
        st = os.statvfs(probe)
        free_gb = (st.f_bavail * st.f_frsize) / (1024 ** 3)
    except Exception:
        free_gb = 0.0
    ok = bool(writable and free_gb >= _SETUP_MIN_FREE_GB)
    return {
        "ok": ok,
        "writable": writable,
        "free_gb": round(free_gb, 1),
        "warn": free_gb < _SETUP_WARN_FREE_GB,
        "min_gb": _SETUP_MIN_FREE_GB,
        "message": ("writable" if writable else "NOT writable") + f", {free_gb:.1f} GB free",
    }


@app.post("/api/setup/configure-local-tls")
def setup_local_tls():
    g = _setup_guard()
    if g:
        return g
    _config_merge({"tls_mode": "local"})
    return {"ok": True, "tls_mode": "local",
            "note": "hosts entries and 'tls internal' are applied by bootstrap.sh on the host."}


@app.post("/api/setup/configure-domain-tls")
def setup_domain_tls(payload: dict = Body(...)):
    g = _setup_guard()
    if g:
        return g
    domain = (payload.get("domain") or "").strip()
    if not domain:
        return JSONResponse({"ok": False, "error": "domain required"}, status_code=400)
    _config_merge({
        "tls_mode": "domain",
        "domain": domain,
        "dns_provider": (payload.get("dns_provider") or "").strip(),
        "dns_api_key": (payload.get("dns_api_key") or "").strip(),
    })
    return {"ok": True, "tls_mode": "domain", "domain": domain,
            "note": "ACME DNS-01 issuance runs via lib/cert-renew.sh on the host."}


@app.post("/api/setup/create-admin")
async def setup_create_admin(payload: dict = Body(...)):
    g = _setup_guard()
    if g:
        return g
    username = (payload.get("username") or "admin").strip()
    password = payload.get("password") or ""
    email = (payload.get("email") or "").strip()
    displayname = (payload.get("displayname") or username).strip()
    if not USERNAME_RE.match(username):
        return JSONResponse({"ok": False, "error": "username must be 3-32 chars: letters, digits, _ or -"}, status_code=400)
    if len(password) < 12:
        return JSONResponse({"ok": False, "error": "password must be at least 12 characters"}, status_code=400)
    pw_hash = _argon_hash(password)

    def mut(order, blocks):
        blocks[username] = _user_block(username, displayname, email, pw_hash, True)
        if username not in order:
            order.append(username)

    try:
        await _usersdb_apply(mut)
    except Exception as exc:
        _log.error("setup create-admin usersdb failed: %s", exc.__class__.__name__)
        return JSONResponse({"ok": False, "error": "failed to write users database"}, status_code=500)
    report = _report(await _prop_create(username, displayname, email, password, True))
    ok = all(r["ok"] for r in report)
    return JSONResponse({"ok": ok, "username": username, "propagation": report},
                        status_code=200 if ok else 207)


@app.post("/api/setup/configure-modules")
def setup_configure_modules(payload: dict = Body(...)):
    g = _setup_guard()
    if g:
        return g
    mods = [m for m in (payload.get("modules") or ["core"]) if m in _SETUP_MODULES]
    if "core" not in mods:
        mods = ["core"] + mods
    if "vpn" in mods and "arr" not in mods:
        return JSONResponse({"ok": False, "error": "vpn module requires the arr module"}, status_code=400)
    patch = {"modules": mods}
    if "vpn" in mods and payload.get("nordvpn_token"):
        patch["nordvpn_token"] = payload["nordvpn_token"]
    _config_merge(patch)
    return {"ok": True, "modules": mods,
            "note": "module containers are brought up by bootstrap.sh on the host."}


@app.get("/api/setup/totp-enroll")
def setup_totp_enroll(username: str = "admin"):
    g = _setup_guard()
    if g:
        return g
    secret = _totp_secret()
    issuer = "FCUK-EM-ALL"
    uri = f"otpauth://totp/{issuer}:{username}?secret={secret}&issuer={issuer}&period=30&digits=6"
    return {"secret": secret, "otpauth_uri": uri, "issuer": issuer}


@app.post("/api/setup/verify-totp")
def setup_verify_totp(payload: dict = Body(...)):
    g = _setup_guard()
    if g:
        return g
    secret = (payload.get("secret") or "").strip()
    if not secret:
        return JSONResponse({"ok": False, "error": "secret required"}, status_code=400)
    ok = _totp_ok(secret, payload.get("code") or "")
    return JSONResponse({"ok": ok, "error": None if ok else "invalid or expired code"},
                        status_code=200 if ok else 400)


@app.post("/api/setup/complete")
def setup_do_complete():
    g = _setup_guard()
    if g:
        return g
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(SETUP_COMPLETE_FILE, "w") as f:
        f.write(_now_stamp() + "\n")
    return {"ok": True, "complete": True}


# ================================================================
# SPA static + routing (Phase 1 - MUST stay last)
# ================================================================
@app.get("/api/{rest:path}")
def api_not_found(rest: str):
    return JSONResponse({"error": "not found", "path": f"/api/{rest}"}, status_code=404)


_ASSETS = os.path.join(_DIST, "assets")
if os.path.isdir(_ASSETS):
    app.mount("/assets", StaticFiles(directory=_ASSETS), name="assets")


@app.get("/{full_path:path}")
def spa(full_path: str):
    candidate = os.path.join(_DIST, full_path)
    if full_path and os.path.isfile(candidate):
        return FileResponse(candidate)
    index = os.path.join(_DIST, "index.html")
    if os.path.isfile(index):
        return FileResponse(index)
    return JSONResponse({"error": "frontend not built"}, status_code=503)
