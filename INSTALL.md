# Install Crucible on your iPhone

Crucible isn't on the App Store. You build it once with [xtool](https://xtool.sh) and sign it with your own Apple ID. A free Apple ID is enough. Plan on about 15 minutes, most of it waiting for the first build.

**You need:** an iPhone on iOS 17 or later, a USB cable, a Mac, a Linux PC or Windows with WSL, and a Plex Media Server you can reach.

## 1. Install xtool

**On a Mac**

1. Install Xcode 26 or newer from the App Store and open it once so it finishes installing.
2. Install xtool:

   ```bash
   brew install xtool-org/tap/xtool
   ```

**On Linux, or Windows with WSL**

1. Install the Swift 6.4 toolchain from <https://swift.org/install/linux>.
2. Install `usbmuxd` (on Debian or Ubuntu: `sudo apt-get install usbmuxd`). On Windows, set up USB passthrough for WSL first, as described in [xtool's guide](https://xtool.sh/documentation/xtooldocs/installation-linux).
3. Download Xcode's `.xip` from <https://developer.apple.com/download/all/?q=Xcode> in your browser and note where it is saved.
4. Install xtool:

   ```bash
   curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
   chmod +x xtool
   sudo mv xtool /usr/local/bin/
   ```

## 2. Sign in to Apple

```bash
xtool setup
```

Pick **1: Password** to use any Apple ID, including a free one, then sign in and enter the two-factor code. Your credentials go only to Apple. On Linux and Windows it then asks for the path to the `.xip` from step 1.

## 3. Build and install

Plug your iPhone in with a cable, unlock it, and tap **Trust** if it asks. Then:

```bash
git clone https://github.com/guitaripod/Crucible
cd Crucible
./scripts/install-ios.sh
```

The script checks that everything is ready, builds Crucible in release mode and installs it. The first build takes several minutes.

If it stops and asks for **Developer Mode**, turn it on in Settings > Privacy & Security, let the phone restart, then run the script again.

## 4. Trust it and open it

On the phone, go to Settings > General > VPN & Device Management, tap your Apple ID, tap **Trust**, then open Crucible and sign in with Plex.

## Good to know

- A free Apple ID's build stops opening after 7 days. Run `./scripts/install-ios.sh` again to renew it.
- To update, run `git pull` and then `./scripts/install-ios.sh`.
- `./scripts/install-ios.sh --check` verifies your setup without building.
- If xtool shows a Trust prompt and then an error, tap Trust and run the script again.
- Crucible talks straight to your Plex server, so a phone away from home needs a route to it, such as Tailscale.
