#!/usr/bin/env python3
"""Puts Crucible in a running Steam's library on the Steam Deck, with its artwork, and launches or closes it there, by
talking to Steam's own interface through its debugger port (127.0.0.1:8080, which Game Mode keeps open). Nothing has to
restart, unlike steam-shortcut.py, which edits Steam's files while it is closed.

    steam-library.py [--exe ~/.local/lib/crucible/crucible] [--art DIR]   add or update the shortcut
    steam-library.py --remove | --run [--options OPTIONS] | --quit | --status

`--run --options` launches with other launch options (`KILN_TRACE=/tmp/t %command% --steam-deck`) and puts the usual ones
back once Steam has started it.
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request

NAME = "Crucible"
LAUNCH_OPTIONS = "--steam-deck"
SHORTCUT_TYPE = 1073741824
ART = {"capsule.png": 0, "hero.png": 1, "logo.png": 2, "wide.png": 3}


class DevTools:
    """A minimal client for one Chrome DevTools websocket: enough to evaluate script in Steam's shared JS context."""

    def __init__(self, url):
        host, port_path = url[len("ws://"):].split(":", 1)
        port, path = port_path.split("/", 1)
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /{path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("Steam closed the debugger connection")
            response += chunk
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise ConnectionError(response.split(b"\r\n", 1)[0].decode())
        self.buffer = response.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("Steam closed the debugger connection")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 1 << 16:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", len(payload))
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + mask + masked)

    def _message(self):
        parts = []
        while True:
            first, second = self._read(2)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(length)
            opcode = first & 0x0F
            if opcode == 0x8:
                raise ConnectionError("Steam closed the debugger connection")
            if opcode in (0x1, 0x2, 0x0):
                parts.append(payload)
                if first & 0x80:
                    return b"".join(parts).decode()

    def evaluate(self, expression):
        self.next_id += 1
        request = self.next_id
        self._send(json.dumps({"id": request, "method": "Runtime.evaluate",
                               "params": {"expression": expression, "awaitPromise": True, "returnByValue": True}}))
        while True:
            message = json.loads(self._message())
            if message.get("id") != request:
                continue
            result = message.get("result", {})
            if "exceptionDetails" in result:
                raise RuntimeError(result["exceptionDetails"].get("exception", {}).get("description", "script failed"))
            return result.get("result", {}).get("value")


def shared_context(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=10) as response:
        targets = json.load(response)
    for target in targets:
        if target.get("title") == "SharedJSContext":
            return DevTools(target["webSocketDebuggerUrl"])
    sys.exit("steam-library: Steam's SharedJSContext is not open; is Steam running in Game Mode?")


FIND = f"""appStore.allApps.filter(app => app.app_type === {SHORTCUT_TYPE} && app.display_name === {json.dumps(NAME)})
    .map(app => app.appid)"""


def game_id(appid):
    return str(((appid & 0xFFFFFFFF) << 32) | 0x02000000)


def add(steam, exe, art):
    plain_exe = json.dumps(exe)
    plain_start = json.dumps(os.path.dirname(exe) + "/")
    quoted = json.dumps(f'"{exe}"')
    start = json.dumps(f'"{os.path.dirname(exe)}/"')
    icon = ""
    for size in ("512x512", "256x256"):
        candidate = os.path.expanduser(f"~/.local/share/icons/hicolor/{size}/apps/org.guitaripod.Crucible.png")
        if os.path.exists(candidate):
            icon = candidate
            break
    script = f"""(async () => {{
        const found = {FIND};
        const appid = found.length ? found[0] : await SteamClient.Apps.AddShortcut({json.dumps(NAME)}, {plain_exe}, {plain_start}, {json.dumps(LAUNCH_OPTIONS)});
        for (const extra of found.slice(1)) SteamClient.Apps.RemoveShortcut(extra);
        SteamClient.Apps.SetShortcutName(appid, {json.dumps(NAME)});
        SteamClient.Apps.SetShortcutExe(appid, {quoted});
        SteamClient.Apps.SetShortcutStartDir(appid, {start});
        SteamClient.Apps.SetShortcutLaunchOptions(appid, {json.dumps(LAUNCH_OPTIONS)});
        SteamClient.Apps.SetShortcutIcon(appid, {json.dumps(icon)});
        return appid;
    }})()"""
    appid = steam.evaluate(script)
    applied = []
    if art and os.path.isdir(art):
        for name, kind in ART.items():
            path = os.path.join(art, name)
            if not os.path.exists(path):
                continue
            data = base64.b64encode(open(path, "rb").read()).decode()
            steam.evaluate(f"""(async () => {{
                await SteamClient.Apps.ClearCustomArtworkForApp({appid}, {kind});
                await SteamClient.Apps.SetCustomArtworkForApp({appid}, {json.dumps(data)}, "png", {kind});
                return true;
            }})()""")
            applied.append(name.split(".")[0])
    print(f"steam-library: {NAME} is app {appid} ({exe} {LAUNCH_OPTIONS})" + (f", artwork: {', '.join(applied)}" if applied else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--exe", default=os.path.expanduser("~/.local/lib/crucible/crucible"))
    parser.add_argument("--art", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "steam-art"))
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--options", help="launch options for --run, this launch only")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--remove", action="store_true")
    action.add_argument("--run", action="store_true")
    action.add_argument("--quit", action="store_true")
    action.add_argument("--status", action="store_true")
    options = parser.parse_args()
    steam = shared_context(options.port)
    found = steam.evaluate(FIND) or []
    if options.remove:
        for appid in found:
            steam.evaluate(f"SteamClient.Apps.RemoveShortcut({appid})")
        print(f"steam-library: removed {len(found)} shortcut(s)")
    elif options.run or options.quit or options.status:
        if not found:
            sys.exit(f"steam-library: {NAME} is not in the library")
        gid = game_id(found[0])
        if options.run:
            if options.options is not None:
                steam.evaluate(f"SteamClient.Apps.SetShortcutLaunchOptions({found[0]}, {json.dumps(options.options)})")
            steam.evaluate(f'SteamClient.Apps.RunGame("{gid}", "", -1, 100)')
            if options.options is not None:
                time.sleep(3)
                steam.evaluate(f"SteamClient.Apps.SetShortcutLaunchOptions({found[0]}, {json.dumps(LAUNCH_OPTIONS)})")
        elif options.quit:
            steam.evaluate(f'SteamClient.Apps.TerminateApp("{gid}", false)')
        print(f"steam-library: app {found[0]}, game {gid}")
    else:
        add(steam, os.path.abspath(os.path.expanduser(options.exe)), options.art)


if __name__ == "__main__":
    main()
