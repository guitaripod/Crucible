#!/usr/bin/env python3
"""Adds Crucible to Steam as a non-Steam game for Big Picture: `crucible --couch` (Couch density, full screen) with its
icon, in every Steam account on this computer, and picks Steam Input's own gamepad templates for it, the Steam Deck's and
DualSense's with the right trackpad as the mouse. Steam reads both files only when it starts, so it must be closed.

    linux/scripts/steam-shortcut.py [--steam ~/.local/share/Steam] [--exe /usr/bin/crucible] [--remove]
"""
import argparse
import binascii
import os
import re
import shutil
import struct
import subprocess
import sys

NAME = "Crucible"
KEY = NAME.lower()
TEMPLATES = {
    "neptune": "controller_neptune_gamepad+mouse.vdf",
    "ps5": "controller_ps5_gamepad+mouse.vdf",
    "ps5_edge": "controller_ps5_gamepad+mouse.vdf",
    "ps4": "controller_ps4_gamepad+mouse.vdf",
    "xbox360": "controller_xbox360_gamepad_joystick.vdf",
    "xboxone": "controller_xboxone_gamepad_joystick.vdf",
    "switch_pro": "controller_switch_pro_gamepad_joystick.vdf",
    "generic": "controller_generic_gamepad_joystick.vdf",
}


def read_binary_vdf(data, offset=0):
    """A binary VDF map from `offset`, as nested dicts in file order, and where it ended."""
    result = {}
    while True:
        kind = data[offset]
        offset += 1
        if kind == 0x08:
            return result, offset
        end = data.index(b"\0", offset)
        key = data[offset:end].decode("utf-8", "surrogateescape")
        offset = end + 1
        if kind == 0x00:
            result[key], offset = read_binary_vdf(data, offset)
        elif kind == 0x01:
            end = data.index(b"\0", offset)
            result[key] = data[offset:end].decode("utf-8", "surrogateescape")
            offset = end + 1
        elif kind == 0x02:
            result[key] = struct.unpack_from("<i", data, offset)[0]
            offset += 4
        else:
            raise ValueError(f"unknown binary VDF type {kind:#x} at {offset}")


def write_binary_vdf(value):
    out = bytearray()
    for key, item in value.items():
        name = key.encode("utf-8", "surrogateescape") + b"\0"
        if isinstance(item, dict):
            out += b"\x00" + name + write_binary_vdf(item)
        elif isinstance(item, int):
            out += b"\x02" + name + struct.pack("<i", item)
        else:
            out += b"\x01" + name + str(item).encode("utf-8", "surrogateescape") + b"\0"
    return bytes(out + b"\x08")


def shortcut_id(exe, name):
    """Steam's id for a non-Steam game, from its target and name, as a signed 32-bit number."""
    unsigned = (binascii.crc32((exe + name).encode()) & 0xFFFFFFFF) | 0x80000000
    return unsigned - (1 << 32)


def icon_path():
    for base in ("/usr/share/icons/hicolor", os.path.expanduser("~/.local/share/icons/hicolor")):
        for size in ("512x512", "256x256"):
            candidate = os.path.join(base, size, "apps", "org.guitaripod.Crucible.png")
            if os.path.exists(candidate):
                return candidate
    return ""


def update_shortcuts(path, exe, remove):
    data = open(path, "rb").read() if os.path.exists(path) else b"\x00shortcuts\x00\x08\x08"
    root, _ = read_binary_vdf(data)
    shortcuts = root.setdefault("shortcuts", {})
    kept = [item for item in shortcuts.values() if item.get("AppName", item.get("appname")) != NAME]
    if not remove:
        quoted = f'"{exe}"'
        kept.append({
            "appid": shortcut_id(quoted, NAME), "AppName": NAME, "Exe": quoted, "StartDir": f'"{os.path.dirname(exe)}/"',
            "icon": icon_path(), "ShortcutPath": "", "LaunchOptions": "--couch", "IsHidden": 0, "AllowDesktopConfig": 1,
            "AllowOverlay": 1, "OpenVR": 0, "Devkit": 0, "DevkitGameID": "", "DevkitOverrideAppID": 0, "LastPlayTime": 0,
            "FlatpakAppID": "", "tags": {},
        })
    root["shortcuts"] = {str(index): item for index, item in enumerate(kept)}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + ".crucible-backup")
    with open(path + ".tmp", "wb") as file:
        file.write(write_binary_vdf(root))
    os.replace(path + ".tmp", path)


def update_templates(config, remove):
    """Points every controller type's choice for the shortcut at Steam's own gamepad template, in the text VDF where Steam
    keeps each game's choice (the shortcut's lower-cased name is its key)."""
    os.makedirs(config, exist_ok=True)
    for kind, template in TEMPLATES.items():
        path = os.path.join(config, f"configset_controller_{kind}.vdf")
        text = open(path).read() if os.path.exists(path) else '"controller_config"\n{\n}\n'
        text = re.sub(r'\n\t"' + re.escape(KEY) + r'"\n\t\{\n(?:\t\t[^\n]*\n)*\t\}', "", text)
        if not remove:
            entry = f'\t"{KEY}"\n\t{{\n\t\t"template"\t\t"{template}"\n\t}}\n'
            closing = text.rstrip().rfind("}")
            text = text[:closing] + entry + text[closing:]
        with open(path + ".tmp", "w") as file:
            file.write(text)
        os.replace(path + ".tmp", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--steam", default=os.path.expanduser("~/.local/share/Steam"))
    parser.add_argument("--exe", default=shutil.which("crucible") or "/usr/bin/crucible")
    parser.add_argument("--remove", action="store_true", help="take the shortcut and its template choices away again")
    parser.add_argument("--even-if-running", action="store_true", help=argparse.SUPPRESS)
    options = parser.parse_args()
    if not options.even_if_running and subprocess.run(["pgrep", "-x", "steam"], capture_output=True).returncode == 0:
        sys.exit("steam-shortcut: Steam is running and would overwrite the change; quit it first (steam -shutdown)")
    exe = os.path.abspath(os.path.expanduser(options.exe))
    users = os.path.join(options.steam, "userdata")
    accounts = [name for name in os.listdir(users) if name.isdigit() and name != "0"] if os.path.isdir(users) else []
    if not accounts:
        sys.exit(f"steam-shortcut: no Steam accounts under {users}")
    for account in accounts:
        update_shortcuts(os.path.join(users, account, "config", "shortcuts.vdf"), exe, options.remove)
        update_templates(os.path.join(options.steam, "steamapps", "common", "Steam Controller Configs", account, "config"), options.remove)
        print(f"steam-shortcut: {'removed' if options.remove else 'added'} {NAME} for account {account} ({exe} --couch)")


if __name__ == "__main__":
    main()
