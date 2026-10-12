# App Store distribution

Crucible is free software under the GNU General Public License v3.0 (see `LICENSE`). Apple's App Store terms add restrictions the GPL does not allow, so the copyright holders of Crucible, Marcus Ziadé and Midgar Oy, add this permission under section 7 of the GPL, in the same spirit as other open-source App Store apps such as Blink Shell.

## Additional permission

You may convey Crucible, and works based on it, through the Apple App Store and TestFlight under Apple's Media Services Terms and the Apple Developer Program License Agreement, even where those terms impose conditions the GPL would not otherwise allow. The copyright holders will not object to a distribution through the App Store that is a violation of the GPL only because of that conflict.

If you modify Crucible you may remove this permission from your version; if you do not, the permission continues to apply to it.

## What this means in practice

- The source in this repository builds with everything unlocked. `scripts/install-ios.sh` (iPhone, with xtool) and the Xcode project in `tv/` need no account with us and contain no store code.
- The App Store build of Crucible for Plex is free to download and sells an optional Crucible Pro through RevenueCat. You are paying for the signed, updated build and for supporting the work, not for the right to run the code.
- Contributions are accepted under `CONTRIBUTING.md`, which includes the grant that lets the App Store build ship them.
