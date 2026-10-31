# Crucible for iPhone: Xcode project for the App Store

The iPhone app is built two ways from the same sources.

| Path | Builds | Use |
| --- | --- | --- |
| xtool (`scripts/install-ios.sh`, `xtool.yml`, `InfoAdditions.plist`) | the SwiftPM library target `Crucible`, whose `@main` is `Sources/Crucible/App/CrucibleApp.swift` | day-to-day installs on the iPhone from Linux. Untouched: it still builds the unlocked source build (Pro is simply on, no store). |
| Xcode project in `ios/` (this directory) | `ios/project.yml` generates `ios/CrucibleIOS.xcodeproj` | the App Store build: archive and upload with Xcode. Installs the MidgarStore store (`MidgarProAccess`) before the first screen. |

| Target | What it is |
| --- | --- |
| `CrucibleApp` | The app: product `Crucible`, bundle id `com.guitaripod.crucible`, module `Crucible`, iPhone and iPad (`TARGETED_DEVICE_FAMILY` 1,2, several windows), iOS 17. It compiles `Sources/Crucible/**` directly, minus `App/CrucibleApp.swift`, plus `ios/App/Entry.swift`, which opens the MidgarLog file, installs `MidgarProAccess.live()` into `ProAccess.shared` and then runs `UIApplicationMain` with `AppDelegate`. It links the package products `CrucibleCore`, `CrucibleMedia`, `CrucibleStats`, `CrucibleDesign`, `CrucibleStatsUI`, `CrucibleActivity`, `CrucibleStore` and `GRDB`. |
| `CrucibleWidgetsExt` | The Live Activity widget extension (`com.guitaripod.crucible.widgets`, product `CrucibleWidgets`), compiling `Sources/CrucibleWidgets/**` and embedded in the app. |

Info.plist keys are in `ios/project.yml` (they mirror `InfoAdditions.plist` and `CrucibleWidgets-Info.plist`, including the four iPad orientations and `UIApplicationSupportsMultipleScenes`). `ios/Resources/Assets.xcassets` holds the single 1024 `AppIcon` (a copy of `Resources/AppIcon.png`, RGB without alpha) and `ios/Resources/PrivacyInfo.xcprivacy` the app's privacy manifest. There are no entitlements and no App Group on iOS. Version and build number are `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` (keep them equal to `tv/project.yml`).

The generated `ios/CrucibleIOS.xcodeproj`, `ios/Generated/` (Info.plists), `ios/.gen-hash` and `ios/out/` are git-ignored. The scheme is `CrucibleIOS`.


## Package name

The sources use the `package` access level. SwiftPM compiles the package's modules with `-package-name <lowercased directory name of the checkout>`, and the app target compiles `Sources/Crucible` itself, so it must pass the same name. `ios/scripts/generate.sh` computes it and feeds it to `project.yml` as `CRUCIBLE_PACKAGE_NAME`; always generate through it (or `ios.sh generate`), never with a bare `xcodegen generate`, and regenerate if the checkout directory is renamed.

## Commands

Run from the Linux checkout; the Mac does the work. Always set `NAME=<id>`: it selects the remote checkout (`~/Dev/ios/$NAME`), DerivedData and the simulator `CrucibleIOS-$NAME` (iPhone 17 Pro Max, iOS 26.5; `IOS_RUNTIME` and `IOS_SIM_TYPE` override). Builds wait for a Mac build slot like `scripts/mac.sh` does.

```
NAME=x ios/scripts/ios.sh generate          sync, xcodegen (skipped when nothing relevant changed)
NAME=x ios/scripts/ios.sh build             simulator build of the app and the widget extension
NAME=x ios/scripts/ios.sh device-build      generic/platform=iOS Release build, signing off: proves the device slice compiles
NAME=x ios/scripts/ios.sh run [VAR=value ...]   build, install, launch, screenshot to ios/out/run.png
NAME=x ios/scripts/ios.sh shot <name>       screenshot the simulator to ios/out/<name>.png
NAME=x ios/scripts/ios.sh test [-only Class[/test]]   XCUITest bundle CrucibleIOSUITests (ios/UITests); screenshots land in ios/out/ui
NAME=x ios/scripts/ios.sh archive-check     unsigned xcodebuild archive, then checks the app, widget, privacy manifest and icons
NAME=x ios/scripts/ios.sh sim-down [--delete]
```

`run` passes `VAR=value` arguments and every exported `CRUCIBLE_*` variable to the app as `SIMCTL_CHILD_VAR`, so the scripted store works: `CRUCIBLE_PRO=free CRUCIBLE_PRO_STORE=ok NAME=x ios/scripts/ios.sh run`. Build logs stay on the Mac in `~/Dev/ios/$NAME/.ioslogs/`; the command prints only errors and the result line.

`scripts/mac.sh ios` is unaffected: it builds the package scheme `Crucible` without this project.

## Archiving for the App Store

The project is unsigned (`CODE_SIGN_STYLE: Automatic`, no team). On the Mac, in the synced checkout (or any checkout), with the team's distribution signing available to Xcode:

```
cd ~/Dev/ios/<checkout>
ios/scripts/generate.sh
xcodebuild archive -project ios/CrucibleIOS.xcodeproj -scheme CrucibleIOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Crucible.xcarchive \
  DEVELOPMENT_TEAM=<team id> CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Crucible.xcarchive -exportPath build/export \
  -exportOptionsPlist <ExportOptions.plist with method app-store-connect>
```

Or open `ios/CrucibleIOS.xcodeproj`, pick the team for both targets and use Product > Archive, then Distribute App. The app id and `com.guitaripod.crucible.widgets` need App Store profiles; the in-app purchase capability is the only one the app id needs.
