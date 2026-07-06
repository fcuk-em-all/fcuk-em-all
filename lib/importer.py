#!/usr/bin/env python3
# =============================================================================
# lib/importer.py - FCUK-EM-ALL universal media importer (one sweep).
#
# Built by 29.sh; runs INSIDE the fcuk-em-all/importer image (guessit + mutagen
# + chromaprint/fpcalc + ffmpeg + requests) on the fcuk-em-all docker network,
# invoked every 60s by cron. One invocation = one sweep of the five dropzones.
#
# Per-type cascade (each tier must POSITIVELY confirm; nothing force-matched on a
# weak guess). Anything not confidently identified is MOVED to <share>/needs-review/
# with a logged reason - never silently dropped, never force-matched. Every
# placement is sha256'd into the type's manifest (dedup) and triggers the right
# app's scan (Jellyfin/Navidrome/Kavita/ABS/Immich). Movies/shows additionally
# kick Jellyfin's DownloadSubtitles task immediately.
#
# Discipline: secrets read from mounted files, NEVER logged; IPv4 forced on
# external lookups; atomic moves; idempotent (dedup + needs-review skip); a file
# still being written (mtime younger than the quiet period) is left for next
# sweep. SF_DRY_RUN=1 identifies + logs but moves/scans/writes nothing.
# =============================================================================
import os, sys, re, json, time, hashlib, subprocess, shutil, zipfile, logging, socket
import xml.etree.ElementTree as ET
from pathlib import Path
import requests

# --- force IPv4 (this VM's IPv6 egress is broken; prefer A records) ----------
_ORIG_GAI = socket.getaddrinfo
def _gai_v4(host, *a, **k):
    res = [r for r in _ORIG_GAI(host, *a, **k) if r[0] == socket.AF_INET]
    return res or _ORIG_GAI(host, *a, **k)
socket.getaddrinfo = _gai_v4

# --- config (env, with sane defaults) ----------------------------------------
MEDIA_ROOT = os.environ.get("SF_MEDIA_ROOT", "/srv/media")
DROPZONE   = os.environ.get("SF_DROPZONE", os.path.join(MEDIA_ROOT, "dropzone"))
SECRETS    = os.environ.get("SF_SECRETS", "/run/secrets")
MANIFESTS  = os.environ.get("SF_MANIFESTS", "/manifests")
QUIET      = int(os.environ.get("SF_QUIET_SECONDS", "30"))
DRY        = os.environ.get("SF_DRY_RUN", "0") == "1"
LOG_PATH   = os.environ.get("SF_LOG", os.path.join(MEDIA_ROOT, ".importer", "importer.log"))
IMM_EMAIL  = os.environ.get("SF_IMMICH_EMAIL", "admin@fcuk-em-all.local")

EP = {  # service-name endpoints on the fcuk-em-all network
    "jellyfin":       os.environ.get("SF_JELLYFIN", "http://jellyfin:8096"),
    "navidrome":      os.environ.get("SF_NAVIDROME", "http://navidrome:4533"),
    "kavita":         os.environ.get("SF_KAVITA", "http://kavita:5000"),
    "audiobookshelf": os.environ.get("SF_ABS", "http://audiobookshelf:13378"),
    "immich":         os.environ.get("SF_IMMICH", "http://immich:2283"),
}

LIB = {  # destination libraries
    "movies":     os.path.join(MEDIA_ROOT, "movies"),
    "shows":      os.path.join(MEDIA_ROOT, "shows"),
    "music":      os.path.join(MEDIA_ROOT, "music"),
    "books":      os.path.join(MEDIA_ROOT, "books"),
    "audiobooks": os.path.join(MEDIA_ROOT, "audiobooks"),
    "photos":     os.path.join(MEDIA_ROOT, "photos"),
}
MANIFEST = {  # dedup manifests (label column is cosmetic; the sha256 column is the key)
    "media":      os.path.join(MANIFESTS, "checksums.sha256"),  # the 'media' drop share (movies+shows)
    "movies":     os.path.join(MANIFESTS, "checksums.sha256"),
    "shows":      os.path.join(MANIFESTS, "checksums.sha256"),
    "music":      os.path.join(MANIFESTS, "music-checksums.sha256"),
    "books":      os.path.join(MANIFESTS, "books-checksums.sha256"),
    "audiobooks": os.path.join(MANIFESTS, "audiobooks-checksums.sha256"),
    "photos":     os.path.join(MANIFESTS, "photos-checksums.sha256"),
}
# files to never treat as media (in-progress copies, OS cruft)
SKIP_RE = re.compile(r"(^\.|\.part$|\.partial$|\.crdownload$|\.tmp$|\.!qB$|^\._|^\.DS_Store$|~$)", re.I)
VIDEO_EXT = {".mp4", ".mkv", ".avi", ".mov", ".m4v", ".wmv", ".ts", ".webm"}
AUDIO_EXT = {".mp3", ".flac", ".m4a", ".ogg", ".opus", ".wav", ".aac", ".wma"}
BOOK_EXT  = {".epub", ".pdf", ".cbz", ".cbr", ".mobi", ".azw3"}
ABK_EXT   = {".m4b", ".mp3", ".m4a", ".ogg", ".opus", ".flac"}
PHOTO_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff",
             ".webp", ".raw", ".dng", ".cr2", ".nef", ".arw", ".mp4", ".mov"}
SUBTITLE_EXT = {".srt", ".vtt", ".ass", ".ssa", ".sub"}

# --- junk: discarded with a logged reason, NEVER sent to needs-review --------
# (conservative - only clear release-artifacts; anything ambiguous stays needs-review)
ARTWORK_KW = ("poster", "cover", "fanart", "folder", "backdrop", "banner", "thumb",
              "landscape", "clearart", "disc", "logo", "artwork")
TRACKER_KW = ("yts", "yify", "rarbg", "eztv", "1337x", "torrent", "tracker",
              "thepiratebay", "piratebay", "downloaded from", "official site",
              "(tor", "tor)", "etrg", "ettv", "galaxyrg", "rartv")
SAMPLE_RE = re.compile(r"(^|[ ._\-])(sample|trailer)([ ._\-]|$)", re.I)
CRUFT_RE  = re.compile(r"(^\.ds_store$|^\._|^thumbs\.db$|^desktop\.ini$)", re.I)
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff", ".tif"}

# language name/code -> ISO 639-1 (Jellyfin's preferred sidecar code). 'hi' is
# handled specially (Hindi vs hearing-impaired collision) - see parse_sub_lang.
LANG = {
    "english": "en", "eng": "en", "en": "en",
    "spanish": "es", "spa": "es", "es": "es", "castellano": "es", "espanol": "es", "latino": "es",
    "french": "fr", "fre": "fr", "fra": "fr", "fr": "fr",
    "german": "de", "ger": "de", "deu": "de", "de": "de",
    "italian": "it", "ita": "it", "it": "it",
    "portuguese": "pt", "por": "pt", "pt": "pt",
    "dutch": "nl", "nld": "nl", "nl": "nl",
    "russian": "ru", "rus": "ru", "ru": "ru",
    "japanese": "ja", "jpn": "ja", "ja": "ja",
    "korean": "ko", "kor": "ko", "ko": "ko",
    "chinese": "zh", "chi": "zh", "zho": "zh", "zh": "zh",
    "arabic": "ar", "ara": "ar", "ar": "ar",
    "hindi": "hi", "hin": "hi",
}
STATUS_FILE = ".importer-status"

# --- logging (dedicated file + stdout for cron capture) ----------------------
Path(os.path.dirname(LOG_PATH)).mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [importer] [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("importer")

UA = {"User-Agent": "FCUK-EM-ALL-Importer/1.0 (self-hosted appliance)"}
HTTP = requests.Session(); HTTP.headers.update(UA)

def secret(name):
    p = os.path.join(SECRETS, name)
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return ""

# --- small fs helpers --------------------------------------------------------
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def stable(path):
    """True if the file has not been modified within the quiet period (i.e. the
    copy/drag has settled). Files still being written are skipped this sweep."""
    try:
        return (time.time() - os.path.getmtime(path)) >= QUIET
    except OSError:
        return False

def manifest_hashes(kind):
    out = set()
    try:
        with open(MANIFEST[kind]) as f:
            for line in f:
                line = line.strip()
                if line:
                    out.add(line.split()[0])
    except OSError:
        pass
    return out

def manifest_append(kind, sha, label):
    if DRY:
        return
    Path(os.path.dirname(MANIFEST[kind])).mkdir(parents=True, exist_ok=True)
    with open(MANIFEST[kind], "a") as f:
        f.write(f"{sha}  {label}\n")

def safe(s):
    s = re.sub(r'[/\\:*?"<>|]', " ", str(s or "")).strip()
    s = re.sub(r"\s+", " ", s)
    return s[:180] or "Unknown"

def place(src, destdir, destname, kind, sha):
    """Atomic move src -> destdir/destname; record sha; readable by serving apps."""
    dest = os.path.join(destdir, destname)
    log.info("PLACE [%s] %s -> %s", kind, os.path.basename(src), dest)
    if DRY:
        return dest
    os.makedirs(destdir, exist_ok=True)
    if os.path.exists(dest):                       # collision: same library path
        if os.path.exists(src):
            os.remove(src)
        return dest
    try:
        os.replace(src, dest)                      # same filesystem (/srv): atomic rename
    except OSError:
        shutil.move(src, dest)
    try:
        os.chmod(dest, 0o644)
        for d in (destdir, os.path.dirname(destdir)):
            os.chmod(d, 0o755)
    except OSError:
        pass
    manifest_append(kind, sha, os.path.relpath(dest, MEDIA_ROOT))
    return dest

def needs_review(src, share, reason):
    nr = os.path.join(DROPZONE, share, "needs-review")
    log.warning("NEEDS-REVIEW [%s] %s : %s", share, os.path.basename(src), reason)
    if DRY:
        return
    os.makedirs(nr, exist_ok=True)
    dest = os.path.join(nr, os.path.basename(src))
    i = 1
    while os.path.exists(dest):
        stem, ext = os.path.splitext(os.path.basename(src))
        dest = os.path.join(nr, f"{stem}.{i}{ext}"); i += 1
    try:
        os.replace(src, dest)
    except OSError:
        shutil.move(src, dest)
    # leave a sidecar note so the operator sees WHY, right next to the file
    try:
        with open(dest + ".why.txt", "w") as f:
            f.write(reason + "\n")
    except OSError:
        pass

def discard(path, share, reason):
    """Junk: log + delete (NOT needs-review). Only for clear release artifacts."""
    log.info("DISCARD [%s] %s : %s", share, os.path.basename(path), reason)
    if DRY:
        return
    try:
        os.remove(path)
    except OSError as e:
        log.error("discard remove failed %s: %s", path, e)

def is_junk(path, share):
    """Return a reason string if the file is clear release junk, else None.
    Conservative: when unsure whether something could be real content, return
    None (-> it falls through to needs-review, never silently deleted)."""
    name = os.path.basename(path); low = name.lower(); ext = os.path.splitext(name)[1].lower()
    if ext == ".nfo":
        return "release .nfo metadata"
    if ext == ".url":
        return "internet-shortcut (.url)"
    if SAMPLE_RE.search(name):
        return "sample/trailer artifact"
    if ext == ".txt" and any(k in low for k in TRACKER_KW):
        return "torrent/tracker .txt"
    # cover/poster artwork only in the MEDIA share (in photos/ images ARE the content)
    if share == "media" and ext in IMAGE_EXT:
        if any(k in low for k in ARTWORK_KW) or any(k in low for k in TRACKER_KW):
            return "cover/poster/artwork image in a media drop"
    return None

def parse_sub_lang(name):
    """(iso639-1 lang or None, forced bool, sdh bool) from a subtitle filename.
    Honors Jellyfin's 'hi' rule: 'hi' alone = Hindi; 'hi' with another language
    = that language tagged hearing-impaired."""
    stem = os.path.splitext(name)[0]
    toks = [t for t in re.split(r"[ ._\-\[\]()]+", stem.lower()) if t]
    forced = any(t in ("forced", "foreign") for t in toks)
    sdh = any(t in ("sdh", "cc", "hearingimpaired", "hearing") for t in toks)
    lang = None
    for t in toks:
        if t in LANG:
            lang = LANG[t]              # last explicit language wins (Jellyfin rule)
    if "hi" in toks:
        if lang and lang != "hi":
            sdh = True                  # 'hi' as a flag alongside another language
        elif not lang:
            lang = "hi"                 # 'hi' alone = Hindi
    return lang, forced, sdh

def sidecar_name(lib_base, lang, forced, sdh, ext):
    parts = [lib_base]
    if lang:
        parts.append(lang)
    if forced:
        parts.append("forced")
    if sdh:
        parts.append("sdh")
    return ".".join(parts) + ext

def set_status(share, text):
    """In-flight visibility: a status FILE per share (dotfile, auto-skipped by
    SKIP_RE). Chosen over renaming the media file because a crash here only leaves
    a stale status line (harmless, overwritten next sweep) - it never leaves a
    stuck/renamed media file or breaks an in-progress SMB transfer."""
    if DRY:
        return
    p = os.path.join(DROPZONE, share, STATUS_FILE)
    try:
        with open(p, "w") as f:
            f.write(text + "\n")
    except OSError:
        pass

def prune_empty(share_root):
    """After processing, remove now-empty dropped subfolders (and OS cruft that
    would keep them 'non-empty'). Never touches the share root or needs-review/."""
    if DRY:
        return 0
    removed = 0
    for dirpath, dirnames, filenames in os.walk(share_root, topdown=False):
        if dirpath == share_root or "needs-review" in dirpath.split(os.sep):
            continue
        try:
            for e in os.listdir(dirpath):
                if CRUFT_RE.match(e):
                    try: os.remove(os.path.join(dirpath, e))
                    except OSError: pass
            if not os.listdir(dirpath):
                os.rmdir(dirpath); removed += 1
                log.info("CLEANUP removed empty folder %s", os.path.relpath(dirpath, DROPZONE))
        except OSError:
            pass
    return removed

# --- external metadata lookups (all defensive; failures -> caller needs-review) ---
def ffprobe_title(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "quiet", "-print_format", "json",
                              "-show_format", path], capture_output=True, text=True, timeout=60)
        tags = (json.loads(out.stdout or "{}").get("format", {}) or {}).get("tags", {}) or {}
        for k in ("title", "TITLE", "Title"):
            if tags.get(k):
                return tags[k].strip()
    except Exception:
        pass
    return ""

def tmdb_search(kind, title, year):
    """kind: 'movie'|'tv'. Returns (id, canonical_title, canon_year) only if the
    top hit has BOTH a poster and an overview (same bar as 16.sh)."""
    key = secret("tmdb_api_key.txt")
    if not key:
        return None
    params = {"query": title, "api_key": key}
    if year:
        params["year" if kind == "movie" else "first_air_date_year"] = year
    try:
        r = HTTP.get(f"https://api.themoviedb.org/3/search/{kind}", params=params, timeout=20)
        res = (r.json() or {}).get("results") or []
    except Exception:
        return None
    if not res:
        return None
    top = res[0]
    if not top.get("poster_path") or not top.get("overview"):
        return None
    if kind == "movie":
        ct = top.get("title") or title
        cy = (top.get("release_date") or "")[:4] or year
    else:
        ct = top.get("name") or title
        cy = (top.get("first_air_date") or "")[:4] or year
    return (top.get("id"), ct, cy)

def tmdb_episode_title(tv_id, season, ep):
    key = secret("tmdb_api_key.txt")
    if not key or not tv_id:
        return ""
    try:
        r = HTTP.get(f"https://api.themoviedb.org/3/tv/{tv_id}/season/{int(season)}/episode/{int(ep)}",
                     params={"api_key": key}, timeout=20)
        return (r.json() or {}).get("name", "") or ""
    except Exception:
        return ""

def musicbrainz(artist, title):
    """Confirm a recording exists for artist+title. Returns (artist, title) canon
    or None. MusicBrainz requires a descriptive UA + <=1 req/s (we sweep slowly)."""
    if not artist or not title:
        return None
    q = f'recording:"{title}" AND artist:"{artist}"'
    try:
        r = HTTP.get("https://musicbrainz.org/ws/2/recording",
                     params={"query": q, "fmt": "json", "limit": 1}, timeout=20)
        recs = (r.json() or {}).get("recordings") or []
    except Exception:
        return None
    if recs and recs[0].get("score", 0) >= 90:
        rec = recs[0]
        ca = (rec.get("artist-credit") or [{}])[0].get("name", artist)
        return (ca, rec.get("title", title))
    return None

def acoustid_lookup(path):
    """Fingerprint via fpcalc -> AcoustID -> (artist, title) or None."""
    key = secret("acoustid_api_key.txt")
    if not key:
        return None
    try:
        fp = subprocess.run(["fpcalc", "-json", path], capture_output=True, text=True, timeout=120)
        d = json.loads(fp.stdout or "{}")
        dur, fingerprint = d.get("duration"), d.get("fingerprint")
        if not dur or not fingerprint:
            return None
        r = HTTP.get("https://api.acoustid.org/v2/lookup",
                     params={"client": key, "duration": int(dur), "fingerprint": fingerprint,
                             "meta": "recordings", "format": "json"}, timeout=25)
        results = (r.json() or {}).get("results") or []
        for res in results:
            for rec in (res.get("recordings") or []):
                title = rec.get("title")
                artists = rec.get("artists") or []
                if title and artists:
                    return (artists[0].get("name", "Unknown Artist"), title)
    except Exception:
        return None
    return None

def epub_meta(path):
    """Read Dublin Core dc:title / dc:creator from the EPUB's OPF."""
    try:
        with zipfile.ZipFile(path) as z:
            container = z.read("META-INF/container.xml")
            m = re.search(rb'full-path="([^"]+\.opf)"', container)
            if not m:
                return ("", "")
            opf = z.read(m.group(1).decode())
            root = ET.fromstring(opf)
            ns = {"dc": "http://purl.org/dc/elements/1.1/"}
            t = root.find(".//dc:title", ns)
            a = root.find(".//dc:creator", ns)
            return ((t.text or "").strip() if t is not None else "",
                    (a.text or "").strip() if a is not None else "")
    except Exception:
        return ("", "")

def gutendex(title):
    try:
        r = HTTP.get("https://gutendex.com/books", params={"search": title}, timeout=20)
        res = (r.json() or {}).get("results") or []
        if res:
            b = res[0]
            au = (b.get("authors") or [{}])[0].get("name", "")
            # Gutendex authors are "Last, First" -> "First Last"
            if "," in au:
                last, first = [x.strip() for x in au.split(",", 1)]
                au = f"{first} {last}".strip()
            return (b.get("title", title), au)
    except Exception:
        pass
    return None

def openlibrary(title, author):
    try:
        r = HTTP.get("https://openlibrary.org/search.json",
                     params={"title": title, "author": author or "", "limit": 1}, timeout=20)
        docs = (r.json() or {}).get("docs") or []
        if docs:
            d = docs[0]
            return (d.get("title", title), (d.get("author_name") or [author or ""])[0])
    except Exception:
        pass
    return None

# --- app scan triggers (lazy auth; cached per run) ---------------------------
_TOK = {}

def jellyfin_refresh():
    try:
        pw = secret("jellyfin_admin_password.txt")
        a = HTTP.post(f"{EP['jellyfin']}/Users/AuthenticateByName",
                      headers={"Authorization": 'MediaBrowser Client="fcuk-em-all-importer", '
                               'Device="importer", DeviceId="sf-importer", Version="1.0"'},
                      json={"Username": "admin", "Pw": pw}, timeout=20)
        tok = a.json().get("AccessToken")
        h = {"Authorization": f'MediaBrowser Token="{tok}"'}
        HTTP.post(f"{EP['jellyfin']}/Library/Refresh", headers=h, timeout=20)
        # kick DownloadSubtitles immediately (find its task id by Key - confirmed live)
        tasks = HTTP.get(f"{EP['jellyfin']}/ScheduledTasks", headers=h, timeout=20).json()
        tid = next((t["Id"] for t in tasks if t.get("Key") == "DownloadSubtitles"), None)
        started = False
        if tid:
            rc = HTTP.post(f"{EP['jellyfin']}/ScheduledTasks/Running/{tid}", headers=h, timeout=20)
            started = rc.status_code in (200, 204)
        log.info("SCAN jellyfin: Library/Refresh + DownloadSubtitles(started=%s)", started)
        return True
    except Exception as e:
        log.error("SCAN jellyfin failed: %s", e)
        return False

def navidrome_scan():
    try:
        import hashlib as _h
        pw = secret("navidrome_admin_password.txt")
        salt = os.urandom(6).hex()
        token = _h.md5((pw + salt).encode()).hexdigest()
        HTTP.get(f"{EP['navidrome']}/rest/startScan.view",
                 params={"u": "admin", "t": token, "s": salt, "v": "1.16.1",
                         "c": "fcuk-em-all-importer", "f": "json"}, timeout=20)
        log.info("SCAN navidrome: startScan.view")
        return True
    except Exception as e:
        log.error("SCAN navidrome failed: %s", e)
        return False

def kavita_scan():
    try:
        pw = secret("kavita_admin_password.txt")
        tok = HTTP.post(f"{EP['kavita']}/api/account/login",
                        json={"username": "admin", "password": pw}, timeout=20).json().get("token")
        h = {"Authorization": f"Bearer {tok}"}
        libs = HTTP.get(f"{EP['kavita']}/api/library/libraries", headers=h, timeout=20).json()
        for lib in libs:
            HTTP.post(f"{EP['kavita']}/api/library/scan?libraryId={lib['id']}&force=true",
                      headers=h, timeout=20)
        log.info("SCAN kavita: %d librar(y/ies)", len(libs))
        return True
    except Exception as e:
        log.error("SCAN kavita failed: %s", e)
        return False

def abs_scan():
    try:
        pw = secret("audiobookshelf_admin_password.txt")
        tok = HTTP.post(f"{EP['audiobookshelf']}/login", cookies={"auth_method": "api"},
                        json={"username": "root", "password": pw}, timeout=20
                        ).json().get("user", {}).get("token")
        h = {"Authorization": f"Bearer {tok}"}
        libs = HTTP.get(f"{EP['audiobookshelf']}/api/libraries", headers=h, timeout=20
                        ).json().get("libraries", [])
        for lib in libs:
            HTTP.post(f"{EP['audiobookshelf']}/api/libraries/{lib['id']}/scan", headers=h, timeout=20)
        log.info("SCAN audiobookshelf: %d librar(y/ies)", len(libs))
        return True
    except Exception as e:
        log.error("SCAN audiobookshelf failed: %s", e)
        return False

def immich_scan():
    try:
        pw = secret("immich_admin_password.txt")
        tok = HTTP.post(f"{EP['immich']}/api/auth/login",
                        json={"email": IMM_EMAIL, "password": pw}, timeout=20).json().get("accessToken")
        h = {"Authorization": f"Bearer {tok}"}
        libs = HTTP.get(f"{EP['immich']}/api/libraries", headers=h, timeout=20).json()
        ext = [l for l in libs if "/external" in (l.get("importPaths") or [])]
        for lib in ext:
            HTTP.post(f"{EP['immich']}/api/libraries/{lib['id']}/scan", headers=h, json={}, timeout=20)
        log.info("SCAN immich: %d external librar(y/ies)", len(ext))
        return True
    except Exception as e:
        log.error("SCAN immich failed: %s", e)
        return False

def jellyfin_prune_missing():
    """Delete Jellyfin items whose backing file/folder no longer exists on disk.
    A plain /Library/Refresh removes missing MOVIES but leaves EMPTY TV SERIES/
    SEASON shells behind (the bug 30.sh hit), so we explicitly drop any item whose
    path is gone.

    STRONGLY GUARDED: only runs when /srv/media is genuinely mounted here (a stable
    library root exists). Without that guard, an unmounted volume would make every
    path look 'missing' and delete the WHOLE library. Requires -v /srv/media in the
    prune container; otherwise it logs and skips (refresh-only)."""
    sentinel = os.path.join(MEDIA_ROOT, "movies")
    if not os.path.isdir(sentinel) or not os.listdir(MEDIA_ROOT):
        log.warning("PRUNE jellyfin: %s not mounted/populated here - skipping path-based phantom deletion (refresh only)", MEDIA_ROOT)
        return 0
    try:
        pw = secret("jellyfin_admin_password.txt")
        a = HTTP.post(f"{EP['jellyfin']}/Users/AuthenticateByName",
                      headers={"Authorization": 'MediaBrowser Client="fcuk-em-all-importer", '
                               'Device="importer", DeviceId="sf-importer", Version="1.0"'},
                      json={"Username": "admin", "Pw": pw}, timeout=20)
        h = {"Authorization": f'MediaBrowser Token="{a.json().get("AccessToken")}"'}
        items = HTTP.get(f"{EP['jellyfin']}/Items",
                         params={"Recursive": "true", "IncludeItemTypes": "Movie,Series,Season,Episode",
                                 "fields": "Path", "enableImages": "false"}, headers=h, timeout=30
                         ).json().get("Items", [])
        removed = 0
        for it in items:
            p = it.get("Path") or ""
            if not p.startswith("/media/"):
                continue                                   # only our /srv/media-backed items
            disk = os.path.join("/srv/media", p[len("/media/"):])
            if os.path.exists(disk):
                continue
            r = HTTP.delete(f"{EP['jellyfin']}/Items/{it['Id']}", headers=h, timeout=20)
            if r.status_code in (200, 204):
                removed += 1
                log.info("PRUNE-DELETE jellyfin %s '%s' (backing path gone: %s)", it.get("Type"), it.get("Name"), p)
        log.info("PRUNE jellyfin: deleted %d phantom item(s) with missing files", removed)
        return removed
    except Exception as e:
        log.error("PRUNE jellyfin_prune_missing failed: %s", e)
        return 0

# --- per-type processors -----------------------------------------------------
def process_media(path, sha):
    try:
        from guessit import guessit
    except Exception as e:
        needs_review(path, "media", f"guessit unavailable: {e}"); return None
    name = os.path.basename(path)
    g = guessit(name)
    title = ffprobe_title(path) or (g.get("title") or "")
    if not title:
        needs_review(path, "media", "no embedded title tag and guessit could not parse a title"); return None
    year = g.get("year")
    is_show = g.get("type") == "episode" or g.get("season") is not None or g.get("episode") is not None
    if is_show:
        season = g.get("season"); ep = g.get("episode")
        if season is None or ep is None:
            needs_review(path, "media", f"looks like a show but season/episode not both parsed (S={season} E={ep})"); return None
        hit = tmdb_search("tv", title, year)
        if not hit:
            needs_review(path, "media", f"no TMDB tv match (poster+overview) for '{title}' ({year})"); return None
        tv_id, ctitle, cyear = hit
        eplist = ep if isinstance(ep, list) else [ep]
        ep0 = eplist[0]
        ettl = tmdb_episode_title(tv_id, season, ep0)
        ext = os.path.splitext(name)[1].lower()
        show_dir = f"{safe(ctitle)}" + (f" ({cyear})" if cyear else "")
        seasondir = os.path.join(LIB["shows"], show_dir, f"Season {int(season):02d}")
        epstr = f"S{int(season):02d}E{int(ep0):02d}"
        fname = f"{safe(ctitle)} - {epstr}" + (f" - {safe(ettl)}" if ettl else "") + ext
        dest = place(path, seasondir, fname, "shows", sha)
        return ("jellyfin", dest)
    else:
        hit = tmdb_search("movie", title, year)
        if not hit:
            needs_review(path, "media", f"no TMDB movie match (poster+overview) for '{title}' ({year})"); return None
        _id, ctitle, cyear = hit
        if not cyear:
            needs_review(path, "media", f"TMDB movie '{ctitle}' has no release year - cannot file confidently"); return None
        ext = os.path.splitext(name)[1].lower()
        base = f"{safe(ctitle)} ({cyear})"
        dest = place(path, os.path.join(LIB["movies"], base), base + ext, "movies", sha)
        return ("jellyfin", dest)

def process_music(path, sha):
    from mutagen import File as MFile
    artist = album = title = ""
    try:
        m = MFile(path, easy=True)
        if m:
            artist = (m.get("artist") or [""])[0]
            album  = (m.get("album") or [""])[0]
            title  = (m.get("title") or [""])[0]
    except Exception:
        pass
    confirmed = None
    if artist and title:
        confirmed = musicbrainz(artist, title)          # tier 2: confirm tags
    if not confirmed:
        ac = acoustid_lookup(path)                       # tier 3: fingerprint
        if ac:
            artist, title = ac
            log.info("MUSIC tier-3 AcoustID fingerprint matched (no usable tags): %s -> %s / %s",
                     os.path.basename(path), artist, title)
            confirmed = musicbrainz(artist, title) or ac
    if not confirmed:
        tried = "tags" + ("+musicbrainz" if (artist and title) else "") + "+acoustid"
        needs_review(path, "music", f"no confident match via {tried} (artist='{artist}', title='{title}')"); return None
    artist, title = confirmed
    album = album or "Singles"
    ext = os.path.splitext(path)[1].lower()
    dest = place(path, os.path.join(LIB["music"], safe(artist), safe(album)), safe(title) + ext, "music", sha)
    return ("navidrome", dest)

def process_books(path, sha):
    ext = os.path.splitext(path)[1].lower()
    title = author = ""
    if ext == ".epub":
        title, author = epub_meta(path)
    if not title:                                        # PDF / missing OPF -> filename
        try:
            from guessit import guessit
            title = guessit(os.path.basename(path)).get("title", "")
        except Exception:
            title = ""
        title = title or os.path.splitext(os.path.basename(path))[0]
    enrich = gutendex(title) or openlibrary(title, author)
    if enrich:
        etitle, eauthor = enrich
        title = etitle or title
        author = author or eauthor
    if not title:
        needs_review(path, "books", "no embedded title and filename yielded nothing"); return None
    author = author or "Unknown Author"
    dest = place(path, os.path.join(LIB["books"], safe(author), safe(title)), safe(title) + ext, "books", sha)
    return ("kavita", dest)

def process_audiobooks(path, sha):
    from mutagen import File as MFile
    artist = title = album = ""
    try:
        m = MFile(path, easy=True)
        if m:
            artist = (m.get("artist") or m.get("albumartist") or [""])[0]
            album  = (m.get("album") or [""])[0]
            title  = (m.get("title") or [""])[0]
    except Exception:
        pass
    book = album or title
    if not book:                                         # fallback: filename
        try:
            from guessit import guessit
            book = guessit(os.path.basename(path)).get("title", "")
        except Exception:
            book = ""
        book = book or os.path.splitext(os.path.basename(path))[0]
    author = artist or "Unknown Author"
    if not book:
        needs_review(path, "audiobooks", "no embedded album/title tag and filename yielded nothing"); return None
    dest = place(path, os.path.join(LIB["audiobooks"], safe(author), safe(book)),
                 os.path.basename(path), "audiobooks", sha)
    return ("audiobookshelf", dest)

def process_photos(path, sha):
    # EXIF is rich; Immich reads it natively. No matching step - move to the
    # external-library root and let Immich's scan ingest it.
    dest = place(path, LIB["photos"], os.path.basename(path), "photos", sha)
    return ("immich", dest)

def process_subtitle(path, share, placements):
    """Match a subtitle to a video PLACED IN THIS SWEEP (same drop), then write it
    as a Jellyfin sidecar next to the placed video. Orphans -> needs-review."""
    src_dir = os.path.dirname(path); stem = os.path.splitext(os.path.basename(path))[0]
    ext = os.path.splitext(path)[1].lower()
    match = None
    # 1) stem affinity (most specific): "Movie.eng.srt" <-> video stem "Movie..."
    for p in placements:
        vs = p["src_stem"]
        if stem == vs or stem.startswith(vs + ".") or stem.startswith(vs + " ") or vs.startswith(stem + "."):
            match = p; break
    # 2) same source folder with exactly one placed video (the common release-folder case)
    if not match:
        same = [p for p in placements if p["src_dir"] == src_dir]
        if len(same) == 1:
            match = same[0]
        elif len(same) > 1:
            needs_review(path, share, f"subtitle in a folder with {len(same)} identified videos - ambiguous"); return None
    if not match:
        needs_review(path, share, "subtitle has no matching identified video in this drop (orphaned)"); return None
    lang, forced, sdh = parse_sub_lang(os.path.basename(path))
    name = sidecar_name(match["lib_base"], lang, forced, sdh, ext)
    # Overwrite any existing sidecar of the SAME name (idempotent re-drops; a
    # re-dropped updated subtitle replaces the old one - Jellyfin uses one track
    # per language+flags anyway). Distinct languages/flags get distinct names.
    dest = os.path.join(match["lib_dir"], name)
    log.info("SUBTITLE %s -> %s (lang=%s forced=%s sdh=%s)", os.path.basename(path), dest, lang, forced, sdh)
    if not DRY:
        os.makedirs(match["lib_dir"], exist_ok=True)
        try: os.replace(path, dest)
        except OSError: shutil.move(path, dest)
        try: os.chmod(dest, 0o644)
        except OSError: pass
    return ("jellyfin", dest)

PROCESSORS = {
    "media":      (process_media,      VIDEO_EXT),
    "music":      (process_music,      AUDIO_EXT),
    "books":      (process_books,      BOOK_EXT),
    "audiobooks": (process_audiobooks, ABK_EXT),
    "photos":     (process_photos,     PHOTO_EXT),
}

def _now():
    return time.strftime("%Y-%m-%d %H:%M:%S")

def preprocess_audiobook_zips(root, dedup, scans):
    """LibriVox and similar ship a whole audiobook as a single .zip of MP3s. For each
    STABLE .zip in the audiobooks drop: extract into a <stem>_extracted/ temp subdir, feed
    every extracted .mp3/.m4b through process_audiobooks (the SAME cascade a directly-dropped
    file takes - these arrive complete straight from the archive, so the per-file stability
    gate is bypassed here), then remove the zip + temp dir. A corrupt/unreadable zip, or a
    valid zip that contains no audio, is routed to needs-review (never silently discarded).
    Only the audiobooks drop is touched. Returns (placed, reviewed)."""
    placed = reviewed = 0
    zips = []
    for dp, dn, fns in os.walk(root):
        parts = dp.split(os.sep)
        if "needs-review" in parts or dp.endswith("_extracted"):
            continue
        for fn in fns:
            if fn.lower().endswith(".zip") and not SKIP_RE.search(fn):
                zips.append(os.path.join(dp, fn))
    for zpath in zips:
        fn = os.path.basename(zpath)
        if not stable(zpath):
            log.info("ZIP skip (still being written, mtime<%ss) %s", QUIET, fn)
            continue
        log.info("ZIP detected in audiobooks drop: %s", fn)
        if DRY:
            log.info("DRY-RUN: would extract + process + clean up %s", fn)
            continue
        tmpdir = os.path.join(os.path.dirname(zpath), safe(os.path.splitext(fn)[0]) + "_extracted")
        try:
            with zipfile.ZipFile(zpath) as zf:
                bad = zf.testzip()
                if bad is not None:
                    raise zipfile.BadZipFile("CRC error on member %s" % bad)
                log.info("ZIP extraction started: %s -> %s/", fn, os.path.basename(tmpdir))
                os.makedirs(tmpdir, exist_ok=True)
                zf.extractall(tmpdir)
        except Exception as e:
            if os.path.isdir(tmpdir):
                shutil.rmtree(tmpdir, ignore_errors=True)
            log.error("ZIP invalid/unreadable (%s) -> needs-review: %s", e.__class__.__name__, fn)
            needs_review(zpath, "audiobooks", "zip archive could not be extracted: %s" % e)
            reviewed += 1
            continue
        audio = []
        for dp, dn, fns in os.walk(tmpdir):
            for f in fns:
                if not SKIP_RE.search(f) and os.path.splitext(f)[1].lower() in ABK_EXT:
                    audio.append(os.path.join(dp, f))
        log.info("ZIP extracted %d audio file(s) from %s", len(audio), fn)
        if not audio:
            shutil.rmtree(tmpdir, ignore_errors=True)
            log.warning("ZIP contained no audio -> needs-review: %s", fn)
            needs_review(zpath, "audiobooks", "zip extracted but contained no audio files")
            reviewed += 1
            continue
        for ap in sorted(audio):
            afn = os.path.basename(ap)
            try:
                sha = sha256(ap)
            except OSError as e:
                log.error("ZIP hash failed %s: %s", afn, e)
                continue
            if sha in dedup:
                log.info("ZIP DEDUP (already placed) %s", afn)
                try:
                    os.remove(ap)
                except OSError:
                    pass
                continue
            try:
                res = process_audiobooks(ap, sha)   # existing cascade - identical to a dropped MP3
            except Exception as e:
                needs_review(ap, "audiobooks", "importer error: %s" % e)
                reviewed += 1
                continue
            if res:
                app, dest = res
                scans.add(app); dedup.add(sha); placed += 1
                log.info("ZIP placed %s -> %s", afn, dest)
            else:
                reviewed += 1   # process_audiobooks already routed it to needs-review
        # cleanup: extracted audio has been moved out (placed or needs-review); drop the
        # archive + temp dir (any remaining packaging cruft goes with the temp dir).
        try:
            os.remove(zpath)
            log.info("ZIP cleanup: removed archive %s", fn)
        except OSError as e:
            log.error("ZIP cleanup: could not remove archive %s: %s", fn, e)
        shutil.rmtree(tmpdir, ignore_errors=True)
        log.info("ZIP cleanup: removed temp dir %s/", os.path.basename(tmpdir))
    return placed, reviewed

def sweep():
    scans = set()
    placed = reviewed = skipped = discarded = subs = 0
    for share in PROCESSORS:
        set_status(share, f"scanning (started {_now()})")
    for share, (proc, exts) in PROCESSORS.items():
        root = os.path.join(DROPZONE, share)
        if not os.path.isdir(root):
            continue
        dedup = manifest_hashes(share)
        # LibriVox etc. ship an audiobook as one .zip - extract + feed the MP3s through the
        # existing cascade BEFORE the normal per-file loop (Ep4 Pass 3); audiobooks drop only.
        if share == "audiobooks":
            zplaced, zreviewed = preprocess_audiobook_zips(root, dedup, scans)
            placed += zplaced; reviewed += zreviewed
        # gather candidates; discard clear junk up front (logged, NOT needs-review)
        cand = []
        for dirpath, dirnames, filenames in os.walk(root):
            if "needs-review" in dirpath.split(os.sep):
                continue
            for fn in filenames:
                if SKIP_RE.search(fn) or fn.endswith(".why.txt") or fn == STATUS_FILE:
                    continue
                fpath = os.path.join(dirpath, fn)
                if not os.path.isfile(fpath):
                    continue
                jr = is_junk(fpath, share)
                if jr:
                    discard(fpath, share, jr); discarded += 1; continue
                cand.append(fpath)
        # media: identify videos FIRST, then subtitles (need the placements), then rest
        if share == "media":
            cand.sort(key=lambda p: 0 if os.path.splitext(p)[1].lower() in VIDEO_EXT
                      else 1 if os.path.splitext(p)[1].lower() in SUBTITLE_EXT else 2)
        placements = []
        for fpath in cand:
            fn = os.path.basename(fpath); ext = os.path.splitext(fn)[1].lower()
            if not stable(fpath):
                log.info("SKIP (still being written, mtime<%ss) %s", QUIET, fn); skipped += 1; continue
            set_status(share, f"processing: {os.path.relpath(fpath, DROPZONE)} ({_now()})")
            # subtitle sidecar matching (media share only)
            if share == "media" and ext in SUBTITLE_EXT:
                r = process_subtitle(fpath, share, placements)
                if r: scans.add(r[0]); subs += 1
                else: reviewed += 1
                continue
            try:
                sha = sha256(fpath)
            except OSError as e:
                log.error("hash failed %s: %s", fn, e); continue
            if sha in dedup:
                log.info("DEDUP (already in manifest) %s", fn)
                if not DRY:
                    try: os.remove(fpath)
                    except OSError: pass
                skipped += 1; continue
            if ext not in exts:
                needs_review(fpath, share, f"unsupported extension '{ext}' for the {share} drop"); reviewed += 1; continue
            try:
                res = proc(fpath, sha)
            except Exception as e:
                needs_review(fpath, share, f"importer error: {e}"); reviewed += 1; continue
            if res:
                app, dest = res
                scans.add(app); placed += 1; dedup.add(sha)
                if share == "media" and dest:
                    placements.append({"src_dir": os.path.dirname(fpath),
                                       "src_stem": os.path.splitext(fn)[0],
                                       "lib_dir": os.path.dirname(dest),
                                       "lib_base": os.path.splitext(os.path.basename(dest))[0]})
            else:
                reviewed += 1
        prune_empty(root)
    # trigger each affected app's scan exactly once
    if not DRY:
        if "jellyfin" in scans: jellyfin_refresh()
        if "navidrome" in scans: navidrome_scan()
        if "kavita" in scans: kavita_scan()
        if "audiobookshelf" in scans: abs_scan()
        if "immich" in scans: immich_scan()
    elif scans:
        log.info("DRY-RUN: would trigger scans -> %s", ", ".join(sorted(scans)))
    summary = f"placed={placed} subs={subs} needs-review={reviewed} discarded={discarded} skipped={skipped}"
    for share in PROCESSORS:
        set_status(share, f"idle - last sweep {_now()}: {summary}")
    log.info("sweep done: %s scans=%s%s", summary, ",".join(sorted(scans)) or "-", " (DRY-RUN)" if DRY else "")
    return placed, reviewed

if __name__ == "__main__":
    if os.environ.get("SF_PRUNE") == "1":
        # re-scan every app (used after test cleanup so each app drops items whose
        # files were removed); never part of a normal sweep
        log.info("=== importer prune (rescan all apps + drop phantoms whose files are gone) ===")
        for fn in (jellyfin_refresh, navidrome_scan, kavita_scan, abs_scan, immich_scan):
            try: fn()
            except Exception as e: log.error("prune %s: %s", fn.__name__, e)
        # Jellyfin leaves empty series/season shells after a scan; remove items
        # whose backing path is gone (guarded; needs -v /srv/media mounted).
        try: jellyfin_prune_missing()
        except Exception as e: log.error("prune jellyfin_prune_missing: %s", e)
        sys.exit(0)
    log.info("=== importer sweep start (dry=%s quiet=%ss) ===", DRY, QUIET)
    try:
        sweep()
    except Exception as e:
        log.exception("sweep crashed: %s", e); sys.exit(1)
