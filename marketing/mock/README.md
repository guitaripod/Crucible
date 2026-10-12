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
- `no_credits=1` (`MOCK_NO_CREDITS`): drops the credits markers, so Up Next comes from the end of the item.
- `latency_ms=N` (`MOCK_LATENCY_MS`): delays every non-`/mock/` response.
- `fail_metadata_once=<ratingKey>` (`MOCK_FAIL_METADATA_ONCE`): the next single-item `/library/metadata/<ratingKey>` request answers 404 (a 5xx would be retried by the app's own client), then the flag clears itself (a resolve that fails once, then succeeds on Retry); `0` clears it.

`GET /mock/log?q=<text>` returns the last 3000 request lines containing `<text>` as a JSON array (`GET /:/timeline?...`), so a UI test can assert which timeline states, transcode starts or pings reached the server.

`./make_hls.sh` cuts `assets/clip.mp4` into `assets/hls` (fMP4, 6 s segments). Once it exists, `/video/:/transcode/universal/start.m3u8` serves that playlist whatever the `offset`, so transcode playback, restarts and pings can be exercised; without it the endpoint answers an empty 200. Every request is logged to stderr, so `/:/timeline`, `ping` and `stop` calls can be checked in the server log.

## In-app demo library

The App Store builds ship the same fictional library inside the app (`Sources/CrucibleDemo`, served over a loopback HTTP server). Its content is exported from this mock's data, so the two stay in step:

    python3 export_demo.py                 # rewrites Sources/CrucibleDemo/Data: library.json, images/, video/
    python3 export_demo.py --skip-video    # catalogue and images only
    python3 export_demo.py --skip-images   # catalogue and video only

Needs Pillow and ffmpeg and the artwork in `assets/` (`python3 art.py` regenerates it). The exporter shrinks the artwork (posters 400x600, backdrops 1280x720, episode stills 480x270, cast avatars 200x200, JPEG quality 62 to 74), writes the catalogue as JSON with watch state as seconds before launch, and builds one 30 second 720p H.264/AAC clip with a synthesised pad and a corner caption, plus the same clip cut into 2 second fMP4 HLS segments. It refuses to finish when the folder exceeds 12 MB. The folder is named `Data` (not `Resources`) because a top-level `Resources` folder inside the flat iOS and tvOS resource bundle makes codesign fail.

The app's history, On Deck and Continue Watching are generated at launch relative to the current date; only the catalogue and its initial watch state come from here. Run `CRUCIBLE_CORE_ONLY=1 swift test --filter CrucibleDemoTests` on the Mac after re-exporting.
