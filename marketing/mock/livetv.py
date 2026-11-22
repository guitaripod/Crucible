"""Live TV for the mock server: Plex's free channels (as epg.provider.plex.tv answers, for clients whose CRUCIBLE_PLEXTV
points here), a DVR with an antenna's channels, its guide, tuning and recordings (the subscription template, scheduled
recordings, rules), and a channel playlist (M3U with an XMLTV guide) whose channels are bare MPEG transport streams sent
at the speed they play, the way IPTV services send them. Every channel and airing is fictional; the picture is the mock's
own clip."""

import hashlib
import os
import subprocess
import threading
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
TS_FILE = os.path.join(ASSETS, "livetv.ts")
DVR_KEY = "7"
EPG = f"tv.plex.providers.epg.cloud:{DVR_KEY}"

FREE = [
    ("ember-news", "Ember News", "news", "News around the clock from the harbour cities."),
    ("northern-lights", "Northern Lights", "explore", "Documentaries from the far north."),
    ("crucible-classics", "Crucible Classics", "movies", "Films from the archive, uncut."),
    ("cartographers", "The Cartographers", "explore", "Maps, journeys and the people who make them."),
    ("harbour-sports", "Harbour Sports", "sports", "Rowing, sailing and the harbour league."),
    ("kitchen-stories", "Kitchen Stories", "food", "Cooking from every coast."),
    ("night-shift", "Night Shift", "crime", "Detective series, back to back."),
    ("little-lanterns", "Little Lanterns", "kids", "Shows for the youngest viewers."),
]
GENRES = {"news": "News", "explore": "Explore", "movies": "Movies", "sports": "Sports", "food": "Food & Home", "crime": "True Crime",
          "kids": "Kids & Family"}
ANTENNA = [("2.1", "KMRN", "Marren Public"), ("4.1", "KVLE", "Vale Four"), ("7.1", "WHAL", "Hale Seven"), ("9.1", "KSTO", "Sato Nine")]
IPTV = [("101", "Lighthouse One", "News"), ("102", "Lighthouse Sport", "Sports"), ("103", "Lighthouse Kids", "Kids"),
        ("104", "Lighthouse Cinema", "Movies")]
SHOWS = ["Harbour Lights", "The Long Crossing", "Ember & Ash", "North of Nowhere", "Saltwater", "The Quiet Coast", "Cartography",
         "Night Ferry", "Lanterns", "The Keeper", "Tidewater", "Glasswork", "Driftwood Kitchen", "The Inspector Calls Again"]
EPISODES = ["Low Tide", "The Signal", "Fog Bank", "First Light", "The Map Room", "Undertow", "A Ship Called Hope", "Breakwater",
            "Lantern Night", "The Last Ferry", "Northbound", "Salt", "The Keeper's Log", "Harbour Master"]

LOCK = threading.Lock()
SUBSCRIPTIONS = {}
SESSIONS = {}


def stable(*parts):
    return int(hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()[:8], 16)


def ensure_assets():
    """The channels' logos (a word mark on a colour) and the transport stream the playlist's channels send, made once."""
    os.makedirs(ASSETS, exist_ok=True)
    try:
        from PIL import Image, ImageDraw, ImageFont
        for key, title, *_ in FREE + [(c, n, "") for c, _, n in ANTENNA] + [(c, n, "") for c, n, _ in IPTV]:
            path = os.path.join(ASSETS, f"livetv_logo_{slug(key)}.png")
            if os.path.exists(path):
                continue
            hue = stable(key) % 360
            image = Image.new("RGB", (420, 280), hsl(hue, 0.55, 0.32))
            draw = ImageDraw.Draw(image)
            font = None
            for candidate in ("/System/Library/Fonts/SFNS.ttf", "/usr/share/fonts/TTF/Inter-Bold.ttf", "/usr/share/fonts/noto/NotoSans-Bold.ttf",
                              "/System/Library/Fonts/Helvetica.ttc"):
                if os.path.exists(candidate):
                    font = ImageFont.truetype(candidate, 54)
                    break
            font = font or ImageFont.load_default()
            words = title.upper().split()
            lines = [" ".join(words[:2]), " ".join(words[2:])] if len(words) > 2 else [title.upper()]
            y = 140 - 34 * len(lines)
            for line in lines:
                width = draw.textlength(line, font=font)
                draw.text(((420 - width) / 2, y), line, font=font, fill=(255, 245, 230))
                y += 68
            image.save(path)
    except ImportError:
        pass
    clip = os.path.join(ASSETS, "clip.mp4")
    if not os.path.exists(TS_FILE) and os.path.exists(clip):
        subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", clip, "-c:v", "libx264", "-preset", "veryfast", "-g", "48",
                        "-keyint_min", "48", "-c:a", "aac", "-f", "mpegts", TS_FILE], check=False)


def hsl(hue, saturation, lightness):
    import colorsys
    r, g, b = colorsys.hls_to_rgb(hue / 360, lightness, saturation)
    return int(r * 255), int(g * 255), int(b * 255)


def slug(text):
    return "".join(c if c.isalnum() else "-" for c in text.lower())


def logo(key):
    return f"/mock/livetv/logo/{slug(key)}.png"


def airings(channel_key, day_start, base_url):
    """A day of airings on a channel, the same every time it is asked: shows of half an hour to two hours."""
    result = []
    t = day_start
    n = 0
    while t < day_start + 86400:
        seed = stable(channel_key, t)
        length = [1800, 1800, 3600, 3600, 5400, 7200][seed % 6]
        show = SHOWS[seed % len(SHOWS)]
        episode = EPISODES[(seed // 7) % len(EPISODES)]
        season, number = 1 + seed % 4, 1 + (seed // 13) % 12
        guid = f"plex://episode/mock-{slug(channel_key)}-{t}"
        result.append({
            "guid": guid, "ratingKey": guid, "key": f"/{EPG}/metadata/{quote(guid, safe='')}", "type": "episode", "title": episode,
            "grandparentTitle": show, "grandparentGuid": f"plex://show/mock-{slug(show)}", "parentIndex": season, "index": number,
            "summary": f"{show}: {episode}. A fictional airing on the mock server's {channel_key} channel.", "contentRating": "TV-PG",
            "thumb": f"{base_url}/library/metadata/{1001 + seed % 20}/art/1", "Genre": [{"tag": "Drama"}],
            "Media": [{"beginsAt": t, "endsAt": t + length, "onAir": t <= time.time() < t + length, "premiere": seed % 9 == 0,
                       "channelIdentifier": channel_key, "channelTitle": channel_key, "channelVcn": channel_key}],
        })
        t += length
        n += 1
    return result


def grid(channel_key, date, base_url):
    try:
        day = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    start = int(day.timestamp())
    return airings(channel_key, start - start % 1800, base_url)


def free_channels():
    return [{"id": f"free-{key}", "gridKey": f"free-{key}", "title": title, "thumb": logo(key), "summary": summary, "isHd": True, "hidden": False,
             "genreRatingKeys": [f"genre_{genre}"], "Media": [{"drm": False, "protocol": "hls", "Part": [{"key": f"/mock/livetv/free/{key}.m3u8"}]}]}
            for key, title, genre, summary in FREE]


def provider():
    return {"MediaProvider": {"identifier": "tv.plex.provider.epg", "title": "Live TV", "protocols": ["livetv"],
                              "Feature": [{"type": "grid", "key": "/grid", "GridChannelFilter": [
                                  {"identifier": genre, "genreRatingKey": f"genre_{genre}", "title": title} for genre, title in GENRES.items()]}]}}


def dvr_channels():
    return [{"id": f"antenna-{vcn}", "gridKey": f"antenna-{vcn}", "vcn": vcn, "title": title, "callSign": call, "thumb": logo(vcn), "isHd": "1"}
            for vcn, call, title in ANTENNA]


def template(guid):
    params = f"hints%5Bguid%5D={quote(guid, safe='')}&hints%5Btype%5D=4&params%5BmediaProviderID%5D=13&params%5BlibraryType%5D=2"
    settings = [
        {"id": "minVideoQuality", "label": "Resolution", "type": "int", "default": "0", "value": "0", "hidden": False, "advanced": True,
         "enumValues": "0:Prefer HD|720:HD only"},
        {"id": "recordPartials", "label": "Allow partial airings", "type": "bool", "default": "true", "value": "true", "hidden": False, "advanced": True},
    ]
    return {"MediaContainer": {"size": 1, "SubscriptionTemplate": [{"MediaSubscription": [
        {"parameters": params, "selected": True, "type": 4, "targetLibrarySectionID": 2, "title": "This Episode", "librarySectionTitle": "TV Shows",
         "airingsType": "New Airings Only", "Setting": settings},
        {"parameters": params.replace("hints%5Btype%5D=4", "hints%5Btype%5D=2"), "type": 2, "targetLibrarySectionID": 2, "title": "All Episodes",
         "librarySectionTitle": "TV Shows", "airingsType": "New Airings Only",
         "Setting": [{"id": "onlyNewAirings", "label": "Airings", "type": "int", "value": "1", "enumValues": "0:New and Repeat Airings|1:New Airings Only"}] + settings},
    ]}]}}


def find_airing(guid, base_url):
    now = int(time.time())
    for vcn, _, _ in ANTENNA:
        for airing in airings(f"antenna-{vcn}", now - now % 86400, base_url) + airings(f"antenna-{vcn}", now - now % 86400 + 86400, base_url):
            if airing["guid"] == guid:
                return airing
    return None


def scheduled(base_url):
    with LOCK:
        subscriptions = list(SUBSCRIPTIONS.values())
    operations = []
    for sub in subscriptions:
        airing = find_airing(sub["guid"], base_url)
        if airing:
            now = time.time()
            media = airing["Media"][0]
            status = "inprogress" if media["beginsAt"] <= now < media["endsAt"] else "scheduled"
            operations.append({"id": f"grab-{sub['key']}", "mediaSubscriptionID": sub["key"], "status": status, "percent": 40 if status == "inprogress" else 0,
                               "Metadata": airing})
    return {"MediaContainer": {"size": len(operations), "MediaGrabOperation": operations}}


def playlist(base_url):
    lines = [f'#EXTM3U x-tvg-url="{base_url}/mock/livetv/epg.xml"']
    for number, title, group in IPTV:
        lines.append(f'#EXTINF:-1 tvg-id="{slug(title)}" tvg-chno="{number}" tvg-logo="{base_url}{logo(number)}" group-title="{group}",{title}')
        lines.append(f"{base_url}/mock/livetv/iptv/{number}")
    return "\n".join(lines) + "\n"


def xmltv(base_url):
    now = int(time.time())
    day = now - now % 86400
    parts = ['<?xml version="1.0" encoding="UTF-8"?>', '<tv generator-info-name="crucible-mock">']
    for number, title, _ in IPTV:
        parts.append(f'<channel id="{slug(title)}"><display-name>{title}</display-name></channel>')
    for number, title, _ in IPTV:
        for airing in airings(f"iptv-{number}", day, base_url) + airings(f"iptv-{number}", day + 86400, base_url):
            media = airing["Media"][0]
            start = datetime.fromtimestamp(media["beginsAt"], timezone.utc).strftime("%Y%m%d%H%M%S +0000")
            stop = datetime.fromtimestamp(media["endsAt"], timezone.utc).strftime("%Y%m%d%H%M%S +0000")
            parts.append(f'<programme start="{start}" stop="{stop}" channel="{slug(title)}"><title>{airing["grandparentTitle"]}</title>'
                         f'<sub-title>{airing["title"]}</sub-title><desc>{airing["summary"]}</desc>'
                         f'<episode-num system="xmltv_ns">{airing["parentIndex"] - 1}.{airing["index"] - 1}.</episode-num></programme>')
    parts.append("</tv>")
    return "\n".join(parts)


def stream_ts(handler):
    """The playlist's channel: the mock's clip as an MPEG transport stream, sent no faster than it plays and over again, as an
    IPTV service sends a channel."""
    if not os.path.exists(TS_FILE):
        return handler.not_found()
    data = open(TS_FILE, "rb").read()
    duration = 150.0
    rate = len(data) / duration
    handler.close_connection = True
    handler.send_response(200)
    handler.send_header("Content-Type", "video/mp2t")
    handler.send_header("Connection", "close")
    handler.end_headers()
    chunk = 188 * 700
    started = time.time()
    sent = 0
    try:
        while True:
            for offset in range(0, len(data), chunk):
                piece = data[offset:offset + chunk]
                handler.wfile.write(piece)
                sent += len(piece)
                ahead = sent / rate - (time.time() - started) - 4
                if ahead > 0:
                    time.sleep(ahead)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass


def handle(handler, p, q, base_url):
    """Answers a Live TV request; returns whether it did."""
    one = lambda k, d=None: q.get(k, [d])[0]
    if p == "/lineups/plex/channels":
        handler.send_json({"MediaContainer": {"size": len(FREE), "identifier": "tv.plex.provider.epg", "Channel": free_channels()}})
        return True
    if p == "/grid" or p == f"/{EPG}/grid":
        key = one("channelGridKey", "")
        rows = grid(key, one("date", ""), base_url)
        if rows is None:
            handler.send_json({"Error": {"message": "Invalid value provided for date!"}}, 400)
        else:
            handler.send_json({"MediaContainer": {"size": len(rows), "Metadata": rows}})
        return True
    if p.startswith("/mock/livetv/logo/"):
        name = p.rsplit("/", 1)[-1]
        handler.send_file(os.path.join(ASSETS, f"livetv_logo_{name}"), "image/png")
        return True
    if p.startswith("/mock/livetv/free/") and p.endswith(".m3u8"):
        handler.send_response(302)
        handler.send_header("Location", f"/video/:/transcode/universal/start.m3u8?session=free-{slug(p.rsplit('/', 1)[-1])}&path=/library/metadata/1001")
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True
    if p == "/mock/livetv/playlist.m3u":
        handler.send_text(playlist(base_url), "audio/x-mpegurl")
        return True
    if p == "/mock/livetv/epg.xml":
        handler.send_text(xmltv(base_url), "application/xml")
        return True
    if p.startswith("/mock/livetv/iptv/"):
        stream_ts(handler)
        return True
    if p == "/livetv/dvrs":
        handler.send_json({"MediaContainer": {"size": 1, "Dvr": [{"key": DVR_KEY, "uuid": "mock-dvr", "lineupTitle": "Antenna", "epgIdentifier": EPG,
                                                                    "Device": [{"make": "Silicondust", "model": "HDHomeRun FLEX 4K", "ChannelMapping": [
                                                                        {"channelKey": f"antenna-{vcn}", "enabled": "1"} for vcn, _, _ in ANTENNA]}]}]}})
        return True
    if p == f"/{EPG}/lineups/dvr/channels":
        handler.send_json({"MediaContainer": {"size": len(ANTENNA), "Channel": dvr_channels()}})
        return True
    if p.startswith(f"/livetv/dvrs/{DVR_KEY}/channels/") and p.endswith("/tune"):
        session = str(uuid.uuid4())
        with LOCK:
            SESSIONS[session] = p.split("/")[-2]
        handler.send_json({"MediaContainer": {"size": 1, "Metadata": [{"key": f"/livetv/sessions/{session}", "live": True,
                                                                         "Media": [{"uuid": session}]}]}})
        return True
    if p == "/media/subscriptions/template":
        handler.send_json(template(one("guid", "")))
        return True
    if p == "/media/subscriptions/scheduled":
        handler.send_json(scheduled(base_url))
        return True
    if p == "/media/subscriptions" and handler.command == "POST":
        guid = one("hints[guid]", "")
        key = str(len(SUBSCRIPTIONS) + 1 + stable(guid) % 1000)
        with LOCK:
            SUBSCRIPTIONS[key] = {"key": key, "guid": guid, "type": int(one("type", "4") or 4)}
        handler.send_json({"MediaContainer": {"size": 1, "MediaSubscription": [{"key": key, "type": SUBSCRIPTIONS[key]["type"], "title": guid}]}})
        return True
    if p == "/media/subscriptions":
        with LOCK:
            subs = list(SUBSCRIPTIONS.values())
        rules = []
        for sub in subs:
            airing = find_airing(sub["guid"], base_url)
            rules.append({"key": sub["key"], "type": sub["type"], "title": airing["grandparentTitle"] if airing else sub["guid"],
                          "librarySectionTitle": "TV Shows", "airingsType": "New Airings Only"})
        handler.send_json({"MediaContainer": {"size": len(rules), "MediaSubscription": rules}})
        return True
    if p.startswith("/media/subscriptions/") and handler.command == "DELETE":
        with LOCK:
            SUBSCRIPTIONS.pop(p.rsplit("/", 1)[-1], None)
        handler.send_empty()
        return True
    if p.startswith("/media/grabbers/operations/") and handler.command == "DELETE":
        key = p.rsplit("/", 1)[-1].replace("grab-", "")
        with LOCK:
            SUBSCRIPTIONS.pop(key, None)
        handler.send_empty()
        return True
    return False


def reset():
    with LOCK:
        SUBSCRIPTIONS.clear()
        SESSIONS.clear()
