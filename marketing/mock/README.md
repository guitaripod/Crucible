# Crucible mock Plex server (marketing screenshots)

Fictional library ("Marcus-PC", Movies / TV Shows / Documentaries) served as Plex JSON. Stdlib-only Python 3.

The screenshot harness (`marketing/shots/run.sh`) starts its own copy per `NAME` on a port derived from it (`PORT=` overrides), so parallel runs never share a server or a simulator.

Run (port 32400 by default, override with `PORT=`; stop any real Plex server first):

    python3 server.py
    PORT=32499 python3 server.py

Point the app at `http://<host>:32400`. Auth is ignored. Watch state and progress live in memory and reset on restart.

Regenerate assets (needs Pillow + numpy; fonts from /usr/share/fonts; about 1 min on 28 cores):

    python3 art.py            # posters, backdrops, stills, cast avatars, assets/_contact.jpg
    python3 art.py poster_1001  # only files whose name contains the argument
    ./make_video.sh           # assets/clip.mp4, 150 s 1080p, served for every Part (Range supported)

Validate against the app's real models (Linux, swiftc): start the server, then `PORT=32400 ./check_decode.sh`.
Direct play serves clip.mp4 for every title; history is generated relative to server start time.

## Playback test switches

Runtime switches for player tests, read from `MOCK_*` environment variables at start and changeable while running with `GET /mock/flags?name=value` (the reply lists the current values):

- `clip_markers=1` (`MOCK_CLIP_MARKERS`): moves every credits marker to 110 s so the 150 s clip reaches it (intro markers at 12 to 58 s already fit).
- `fail_parts=1` (`MOCK_FAIL_PARTS`): direct-play part URLs answer 500, which forces the direct-play to transcode fallback.
- `fail_transcode=1` (`MOCK_FAIL_TRANSCODE`): `start.m3u8` answers 500, so a failed fallback reaches the error state.
- `latency_ms=N` (`MOCK_LATENCY_MS`): delays every non-`/mock/` response.

`./make_hls.sh` cuts `assets/clip.mp4` into `assets/hls` (fMP4, 6 s segments). Once it exists, `/video/:/transcode/universal/start.m3u8` serves that playlist whatever the `offset`, so transcode playback, restarts and pings can be exercised; without it the endpoint answers an empty 200. Every request is logged to stderr, so `/:/timeline`, `ping` and `stop` calls can be checked in the server log.
