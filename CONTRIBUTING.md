# Contributing to Crucible

Issues and pull requests are welcome at <https://github.com/guitaripod/Crucible>.

## Before you start

- Read `docs/ARCHITECTURE.md`: logic lives in `CrucibleCore` and the other shared modules, and the iPhone and Apple TV screens only render it.
- The repo rules are in the README and architecture doc: programmatic UIKit, Swift 6, `package` access across modules, no inline comments (a well-named method with a `///` doc comment instead), no `print` (use `MidgarLog` with a Crucible category from `CrucibleLog.swift`).
- Run `scripts/mac.sh core-test` for Core changes and `tv/scripts/tv.sh uitest` for Apple TV changes; both need a Mac.

## Licence of your contribution

Crucible is under the GNU General Public License v3.0, and the App Store build is published by Midgar Oy under the additional permission in `APP_STORE_EXCEPTION.md`. By opening a pull request you confirm that:

1. you wrote the change, or have the right to submit it;
2. you license it under GPL-3.0, like the rest of Crucible;
3. you grant Midgar Oy a perpetual, worldwide, non-exclusive, royalty-free, irrevocable licence to use, modify and distribute your contribution as part of Crucible under any terms, including through the Apple App Store.

Add `Signed-off-by: Your Name <you@example.com>` to each commit (`git commit -s`) to record this.
