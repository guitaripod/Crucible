import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

import library

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
PORT = int(os.environ.get("PORT", "32400"))
LIB = library.Library()
LOCK = threading.Lock()

SRT = (
    "1\n00:00:02,000 --> 00:00:05,000\nWe should not be out here.\n\n"
    "2\n00:00:06,000 --> 00:00:09,500\nThe tide turns in an hour. Then we go.\n\n"
    "3\n00:00:12,000 --> 00:00:15,000\nSomeone has been down there before us.\n\n"
)

SORT_KEYS = {
    "titleSort": lambda i: i["titleSort"],
    "title": lambda i: i["titleSort"],
    "addedAt": lambda i: i["addedAt"],
    "year": lambda i: i.get("year", 0),
    "rating": lambda i: i.get("rating", 0),
    "audienceRating": lambda i: i.get("audienceRating", 0),
    "lastViewedAt": lambda i: i.get("lastViewedAt", 0),
    "originallyAvailableAt": lambda i: i.get("originallyAvailableAt", ""),
}


def container(**fields):
    return {"MediaContainer": fields}


def section_items(section_id):
    kind = library.SECTIONS[section_id][1]
    pool = LIB.movies if kind == "movie" else LIB.shows
    return [i for i in pool if str(i["librarySectionID"]) == section_id]


def paged(items, q, **extra):
    start = int(q.get("X-Plex-Container-Start", ["0"])[0])
    size = int(q.get("X-Plex-Container-Size", ["50"])[0])
    page = items[start:start + size]
    return dict(size=len(page), totalSize=len(items), offset=start, **extra), page


def sorted_items(items, sort):
    field, _, direction = (sort or "titleSort:asc").partition(":")
    key = SORT_KEYS.get(field, SORT_KEYS["titleSort"])
    return sorted(items, key=key, reverse=direction == "desc")


def filter_genre(items, genre):
    if not genre:
        return items
    wanted = set()
    for g in genre.split(","):
        wanted.add(next((n for n, i in library.GENRE_ID.items() if i == g), g))
    return [i for i in items if wanted & set(i["_genres"])]


def hub(identifier, title, items, kind="mixed"):
    return {"type": kind, "hubIdentifier": identifier, "title": title, "size": len(items), "more": False,
            "promoted": True, "Metadata": [LIB.render(i) for i in items]}


def folder_buckets(section_id):
    return [("A-F", "A", "F"), ("G-M", "G", "M"), ("N-S", "N", "S"), ("T-Z", "T", "Z")]


def search_rank(item, q):
    t = item["title"].lower()
    if t.startswith(q):
        return (0, len(t), t)
    if any(w.startswith(q) for w in re.split(r"\W+", t)):
        return (1, len(t), t)
    return (2, len(t), t)


def search_hubs(query):
    q = query.lower().strip()
    if not q:
        return []
    movies = sorted((m for m in LIB.movies if q in m["title"].lower()), key=lambda i: search_rank(i, q))
    shows = sorted((s for s in LIB.shows if q in s["title"].lower()), key=lambda i: search_rank(i, q))
    eps = sorted((e for e in LIB.items.values() if e["type"] == "episode" and q in e["title"].lower()),
                 key=lambda i: search_rank(i, q))
    hubs = []
    for ident, title, kind, items in (("movie", "Movies", "movie", movies), ("show", "Shows", "show", shows),
                                      ("episode", "Episodes", "episode", eps)):
        if items:
            hubs.append(hub(ident, title, items[:30], kind))
    return hubs


def resolve_image(path):
    path = unquote(urlparse(path).path)
    m = re.match(r"^/library/metadata/(\d+)/(thumb|art)(?:/\d+)?$", path)
    if m:
        rk, kind = m.groups()
        it = LIB.items.get(rk)
        if not it:
            return None
        if kind == "art":
            owner = LIB.items[it["_show"]] if it["_kind"] in ("season", "episode") else it
            name = f"backdrop_{owner['ratingKey']}.jpg"
        elif it["_kind"] == "episode":
            name = f"still_{rk}.jpg"
        else:
            name = f"poster_{rk}.jpg"
        return os.path.join(ASSETS, name)
    m = re.match(r"^/actors/([a-z0-9-]+)\.jpg$", path)
    if m:
        return os.path.join(ASSETS, f"actor_{m.group(1)}.jpg")
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "Plex Media Server"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def send_json(self, payload, status=200):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_empty(self, status=200):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def not_found(self):
        self.send_json(container(size=0, error="not found"), 404)

    def send_file(self, path, content_type, ranged=False):
        if not path or not os.path.isfile(path):
            return self.not_found()
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range") if ranged else None
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                a, b = m.groups()
                if a == "" and b:
                    start = max(0, size - int(b))
                elif a:
                    start = int(a)
                    end = min(int(b), size - 1) if b else size - 1
                if start >= size or start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        try:
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(262144, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_HEAD(self):
        self.route()

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.drain()
        self.route()

    def do_PUT(self):
        self.drain()
        self.route()

    def do_DELETE(self):
        self.route()

    def drain(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)

    def route(self):
        try:
            self.dispatch()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            sys.stderr.write(f"ERROR {self.path}: {exc!r}\n")
            try:
                self.send_json(container(size=0, error=str(exc)), 500)
            except Exception:
                pass

    def dispatch(self):
        u = urlparse(self.path)
        p = u.path.rstrip("/") or "/"
        q = parse_qs(u.query)
        one = lambda k, d=None: q.get(k, [d])[0]

        if p in ("/identity", "/"):
            return self.send_json(container(size=0, claimed=True, machineIdentifier=library.MACHINE_ID,
                                            version="1.41.4.9463-630c9f557", friendlyName=library.SERVER_NAME))

        if p.startswith("/:/"):
            with LOCK:
                self.handle_state(p, q)
            return self.send_empty()

        if p == "/library/sections":
            hidden = set(os.environ.get("MOCK_HIDDEN_SECTIONS", "").split(","))
            dirs = [{"key": k, "type": t, "title": n, "agent": f"tv.plex.agents.{t}", "language": "en-US",
                     "refreshing": False, "uuid": f"0000{k}-aaaa-4bbb-8ccc-000000000{k}",
                     "hidden": 1 if k in hidden else 0}
                    for k, (n, t) in library.SECTIONS.items()]
            return self.send_json(container(size=len(dirs), allowLibraryOrder=True, title1="Plex Library", Directory=dirs))

        m = re.match(r"^/library/sections/(\d+)(?:/(all|genre|folder|firstCharacter)(?:/([A-Za-z0-9-]+))?)?$", p)
        if m and m.group(1) in library.SECTIONS:
            return self.section(m.group(1), m.group(2), m.group(3), q)

        m = re.match(r"^/library/metadata/(\d+)(?:/(children))?$", p)
        if m:
            rk, sub = m.groups()
            with LOCK:
                it = LIB.items.get(rk)
                if not it:
                    return self.not_found()
                if sub == "children":
                    kids = LIB.children_of(rk) or []
                    payload = container(size=len(kids), totalSize=len(kids), key=rk, title1=it.get("grandparentTitle") or it["title"],
                                        title2=it["title"], viewGroup=("season" if it["type"] == "show" else "episode"),
                                        Metadata=[LIB.render(k) for k in kids])
                else:
                    payload = container(size=1, Metadata=[LIB.render(it, full=True)])
            return self.send_json(payload)

        m = re.match(r"^/library/metadata/\d+/(thumb|art)(?:/\d+)?$", p) or re.match(r"^/actors/[a-z0-9-]+\.jpg$", p)
        if m:
            return self.send_file(resolve_image(p), "image/jpeg")

        if p == "/photo/:/transcode":
            return self.send_file(resolve_image(one("url", "")), "image/jpeg")

        if re.match(r"^/library/parts/\d+/\d+/file\.\w+$", p):
            return self.send_file(os.path.join(ASSETS, "clip.mp4"), "video/mp4", ranged=True)

        if re.match(r"^/library/parts/\d+$", p):
            return self.send_empty()

        m = re.match(r"^/library/streams/(\d+)$", p)
        if m:
            body = SRT.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return

        if p == "/hubs":
            count = int(one("count", "20"))
            with LOCK:
                hubs = [hub("home.continue", "Continue Watching", LIB.continue_watching()[:count]),
                        hub("home.ondeck", "On Deck", [LIB.items[r] for r in LIB.on_deck
                                                       if not LIB.items[r].get("viewCount")][:count]),
                        hub("home.recentlyadded", "Recently Added", LIB.recently_added()[:max(count, 16)])]
                payload = container(size=len(hubs), allowSync=True, identifier="com.plexapp.plugins.library", Hub=hubs)
            return self.send_json(payload)

        m = re.match(r"^/hubs/sections/(\d+)$", p)
        if m and m.group(1) in library.SECTIONS:
            sid = m.group(1)
            kind = library.SECTIONS[sid][1]
            pool = {i["ratingKey"] for i in section_items(sid)}
            with LOCK:
                cont = [i for i in LIB.continue_watching()
                        if i["ratingKey"] in pool or i.get("grandparentRatingKey") in pool]
                deck = [LIB.items[r] for r in LIB.on_deck
                        if LIB.items[r].get("grandparentRatingKey") in pool or r in pool]
                recent = [i for i in LIB.recently_added() if i["ratingKey"] in pool][:16]
                pre = "movie" if kind == "movie" else "tv"
                hubs = [hub(f"{pre}.inprogress", "Continue Watching", cont, kind)]
                if kind == "show":
                    hubs.append(hub("tv.ondeck", "On Deck", deck, "episode"))
                hubs.append(hub(f"{pre}.recentlyadded", "Recently Added", recent, kind))
                payload = container(size=len(hubs), librarySectionID=int(sid), librarySectionTitle=library.SECTIONS[sid][0],
                                    Hub=hubs)
            return self.send_json(payload)

        if p == "/library/onDeck":
            with LOCK:
                items = [LIB.render(LIB.items[r]) for r in LIB.on_deck if not LIB.items[r].get("viewCount")]
            return self.send_json(container(size=len(items), totalSize=len(items), Metadata=items))

        if p == "/library/recentlyAdded":
            with LOCK:
                c, page = paged(LIB.recently_added(), q)
                c["Metadata"] = [LIB.render(i) for i in page]
            return self.send_json({"MediaContainer": c})

        if p == "/hubs/search":
            hubs = search_hubs(one("query", ""))
            return self.send_json(container(size=len(hubs), Hub=hubs))

        if p == "/status/sessions/history/all":
            with LOCK:
                rows = list(LIB.history)
                sid = one("librarySectionID")
                if sid:
                    rows = [r for r in rows if str(r["librarySectionID"]) == sid]
                if (one("sort") or "viewedAt:desc").endswith(":asc"):
                    rows.sort(key=lambda r: r["viewedAt"])
                c, page = paged(rows, q)
                c["Metadata"] = page
            return self.send_json({"MediaContainer": c})

        if p.startswith("/video/:/transcode/universal/"):
            return self.send_empty()

        self.not_found()

    def handle_state(self, p, q):
        one = lambda k, d=None: q.get(k, [d])[0]
        if p == "/:/scrobble":
            rk = one("key", "")
            LIB.mark_watched(rk, True)
            it = LIB.items.get(rk)
            if it and it["type"] in ("movie", "episode"):
                entry = LIB._entry(it, int(time.time()))
                entry["historyKey"] = f"/status/sessions/history/{len(LIB.history) + 1}"
                LIB.history.insert(0, entry)
        elif p == "/:/unscrobble":
            LIB.mark_watched(one("key", ""), False)
        elif p == "/:/timeline":
            LIB.set_progress(one("ratingKey", ""), int(one("time", "0")), int(one("duration", "0")), one("state", ""))
        elif p == "/:/progress":
            rk = (one("key", "") or "").rsplit("/", 1)[-1]
            it = LIB.items.get(rk)
            if it:
                LIB.set_progress(rk, int(one("time", "0")), it.get("duration", 0), "playing")

    def section(self, sid, what, bucket, q):
        title, kind = library.SECTIONS[sid]
        with LOCK:
            items = section_items(sid)
            if what is None:
                return self.send_json(container(size=1, Directory=[{"key": sid, "type": kind, "title": title}]))
            if what == "all":
                items = filter_genre(items, (q.get("genre") or [None])[0])
                items = sorted_items(items, (q.get("sort") or [None])[0])
                c, page = paged(items, q, librarySectionID=int(sid), librarySectionTitle=title, title1=title,
                                viewGroup=kind)
                c["Metadata"] = [LIB.render(i) for i in page]
                return self.send_json({"MediaContainer": c})
            if what == "firstCharacter":
                counts = {}
                for i in items:
                    letter = i["titleSort"][:1].upper()
                    letter = letter if letter.isalpha() else "#"
                    counts[letter] = counts.get(letter, 0) + 1
                dirs = [{"key": k, "title": k, "size": counts[k]} for k in sorted(counts, key=lambda k: ("\uffff" if k == "#" else k))]
                return self.send_json(container(size=len(dirs), title1=title, Directory=dirs))
            if what == "genre":
                present = sorted({g for i in items for g in i["_genres"]})
                dirs = [{"key": library.GENRE_ID[g], "title": g, "type": "genre",
                         "fastKey": f"/library/sections/{sid}/all?genre={library.GENRE_ID[g]}"} for g in present]
                return self.send_json(container(size=len(dirs), allowSync=False, title1=title, Directory=dirs))
            if what == "folder":
                if bucket is None:
                    dirs = [{"key": f"/library/sections/{sid}/folder/{b[0]}", "title": b[0]}
                            for b in folder_buckets(sid) if any(b[1] <= i["titleSort"][:1].upper() <= b[2] for i in items)]
                    return self.send_json(container(size=len(dirs), title1=title, Directory=dirs))
                b = next((b for b in folder_buckets(sid) if b[0] == bucket), None)
                if not b:
                    return self.not_found()
                sel = sorted((i for i in items if b[1] <= i["titleSort"][:1].upper() <= b[2]), key=lambda i: i["titleSort"])
                return self.send_json(container(size=len(sel), title1=title, title2=bucket, Metadata=[LIB.render(i) for i in sel]))
        self.not_found()


def main():
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    sys.stderr.write(f"Mock Plex server '{library.SERVER_NAME}' on :{PORT}, {len(LIB.items)} items, {len(LIB.history)} history rows\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
