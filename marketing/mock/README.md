# Crucible mock Plex server (marketing screenshots)

Fictional library ("Marcus-PC", Movies / TV Shows / Documentaries) served as Plex JSON. Stdlib-only Python 3.

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
