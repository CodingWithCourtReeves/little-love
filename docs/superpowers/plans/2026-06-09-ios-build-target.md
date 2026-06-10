# iOS Build Target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing Flutter `app/` build, sign, and run on iOS — both simulator and a physical iPhone — without touching feature code.

**Architecture:** Scaffold the missing `app/ios/` target with `flutter create --platforms=ios .`, align the iOS Xcode signing/bundle config with the existing macOS Xcode config (`dev.littlelove.littlelove`, team `33HDFY8B9F`), add a future-proof `NSCameraUsageDescription` for the upcoming WT-D QR scanner, derive an iOS app-icon set from the existing 1024×1024 master PNG, and extend CI with a non-signed `flutter build ios --simulator --no-codesign` job on a macOS runner.

**Tech Stack:** Flutter 3.44.1 (stable), Xcode 26.4, CocoaPods 1.16.2, iOS 13.0 minimum deployment target (Flutter 3.44 stable default), GitHub Actions `macos-latest`.

---

## Pre-flight context (read before starting)

**Discovered repo state:**
- `app/ios/` does NOT exist on this branch — Task 1 scaffolds it from scratch.
- `app/macos/Runner/Configs/AppInfo.xcconfig` → `PRODUCT_BUNDLE_IDENTIFIER = dev.littlelove.littlelove`, `DEVELOPMENT_TEAM = 33HDFY8B9F`, `PRODUCT_NAME = littlelove`.
- `app/pubspec.yaml` does NOT currently list `mobile_scanner` (WT-D has not landed). The plan still adds `NSCameraUsageDescription` proactively per the brief.
- `app/lib/main.dart` is platform-agnostic (`MaterialApp`, `flutter_riverpod`).
- `app/lib/identity/account_local.dart:41-43` uses `Platform.environment['HOME']` for `~/.littlelove/account.json`. On iOS this resolves to the app sandbox HOME, which is writable, so it will work without code changes for this iteration. **No refactor — out of scope.**
- `app/assets/app-icon/littlelove-app-icon-master.png` is a 1024×1024 RGBA PNG. iOS icons will be resized from this existing asset by extending `scripts/generate-app-icons.sh`. This is NOT fabricated icon art.
- CI workflow `flutter` job runs on `ubuntu-latest` and uses Flutter `3.44.x`. A new `ios-build` job will run on `macos-latest` with the same Flutter version.

**Stop conditions** (do not silently work around):
- A plugin in `pubspec.yaml` that lacks an iOS implementation → stop and flag.
- A signing prompt for anything other than the known team `33HDFY8B9F` and bundle ID → stop and ask Court.
- Xcode CLT license prompt or anything requiring `sudo` interactively → stop and ask Court to run `!`-prefixed in his shell.

---

## File Structure

**Created by Task 1 (scaffolded by `flutter create`):**
- `app/ios/Runner.xcodeproj/` (entire Xcode project)
- `app/ios/Runner.xcworkspace/` (CocoaPods workspace)
- `app/ios/Runner/` (Swift entry, Info.plist, Assets.xcassets, AppDelegate.swift)
- `app/ios/RunnerTests/` (Xcode unit test stub)
- `app/ios/Flutter/` (Flutter generated configs, AppFrameworkInfo.plist)
- `app/ios/Podfile`
- `app/ios/.gitignore` (Flutter-generated; may need merging with repo `.gitignore` patterns)

**Modified by later tasks:**
- `app/ios/Runner.xcodeproj/project.pbxproj` — bundle ID, dev team, deployment target (edit via `sed`/`plutil` or by overriding in xcconfig — see Task 2).
- `app/ios/Flutter/AppFrameworkInfo.plist` — MinimumOSVersion if Flutter scaffold differs from target.
- `app/ios/Runner/Info.plist` — add `NSCameraUsageDescription`, set `CFBundleDisplayName` to `LittleLove`.
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/` — populated by the extended icon script.
- `app/ios/Podfile` — set `platform :ios, '13.0'` and a post_install block matching macOS pattern.
- `scripts/generate-app-icons.sh` — add iOS icon-set generation from the master PNG.
- `scripts/ios-run.sh` — NEW helper to launch the app on an iPhone simulator.
- `.github/workflows/ci.yml` — add `ios-build` job.
- `app/README.md` — append a short "iOS build" section with the release one-liner.

---

## Task 1: Scaffold `app/ios/` from Flutter

**Files:**
- Create: `app/ios/` (everything inside, via `flutter create`)

- [ ] **Step 1: From the repo root, run `flutter pub get` once to ensure ephemeral configs exist**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS/app
flutter pub get
```

Expected: "Got dependencies!" — succeeds with no platform errors. macOS/Windows platforms remain untouched.

- [ ] **Step 2: Scaffold the iOS platform**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS/app
flutter create --platforms=ios --org dev.littlelove --project-name littlelove .
```

Expected: `Recreating project ....` and a list of created files all under `ios/`. No `lib/`, `macos/`, `windows/`, or `pubspec.yaml` changes (verify with `git status`).

- [ ] **Step 3: Verify `app/ios/` was created and other platforms untouched**

```bash
git -C /Users/courtreeves/projects/little-love-WT-iOS status --short
```

Expected: only paths under `app/ios/` appear as `??` (untracked). If `app/lib/`, `app/macos/`, `app/windows/`, or `app/pubspec.yaml` show modifications, revert them: `git -C ../ checkout -- app/lib app/macos app/windows app/pubspec.yaml` (only those paths — preserve any untracked `ios/`).

- [ ] **Step 4: Confirm scaffolded bundle ID and platform**

```bash
grep -n "PRODUCT_BUNDLE_IDENTIFIER" /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner.xcodeproj/project.pbxproj | head -3
grep -n "platform :ios" /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Podfile
grep -n "MinimumOSVersion" /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Flutter/AppFrameworkInfo.plist
```

Expected: bundle ID likely `dev.littlelove.littlelove` (because we passed `--org dev.littlelove --project-name littlelove`). Podfile `platform :ios, '13.0'` line may be commented; if so Task 4 uncomments it.

- [ ] **Step 5: Commit the scaffold as a clean baseline**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add app/ios
git commit -m "chore(ios): scaffold app/ios via flutter create (no other changes)"
```

---

## Task 2: Align bundle ID and signing with macOS via xcconfig

**Files:**
- Create: `app/ios/Flutter/AppInfo.xcconfig` (matches the macOS xcconfig pattern at `app/macos/Runner/Configs/AppInfo.xcconfig`)
- Modify: `app/ios/Flutter/Debug.xcconfig`, `app/ios/Flutter/Release.xcconfig` (include AppInfo)
- Modify: `app/ios/Runner.xcodeproj/project.pbxproj` (point Debug/Release/Profile build configs at the xcconfig values via `$(PRODUCT_BUNDLE_IDENTIFIER)` and `$(DEVELOPMENT_TEAM)`)

**Why xcconfig instead of hand-editing pbxproj:** matches the existing macOS pattern (see `app/macos/Runner/Configs/AppInfo.xcconfig:1-21`), keeps signing config out of the Xcode project file, and makes the team ID swappable without touching project.pbxproj.

- [ ] **Step 1: Create the iOS xcconfig**

Write `app/ios/Flutter/AppInfo.xcconfig`:

```xcconfig
// Application-level settings for the iOS Runner target.
// Mirrors app/macos/Runner/Configs/AppInfo.xcconfig so iOS and macOS share
// bundle identifier and development team.

PRODUCT_NAME = littlelove
PRODUCT_BUNDLE_IDENTIFIER = dev.littlelove.littlelove

// Display name shown under the iOS app icon.
PRODUCT_BUNDLE_DISPLAY_NAME = LittleLove

// Apple Developer Team ID — same as macOS. Required so flutter_secure_storage
// can write to the iOS Keychain on signed local-dev builds.
DEVELOPMENT_TEAM = 33HDFY8B9F
CODE_SIGN_STYLE = Automatic

// iOS deployment target. Flutter 3.44 stable defaults to iOS 13.0.
IPHONEOS_DEPLOYMENT_TARGET = 13.0
```

- [ ] **Step 2: Include AppInfo.xcconfig from the Flutter-generated xcconfigs**

Edit `app/ios/Flutter/Debug.xcconfig` — prepend a line so the file becomes:

```xcconfig
#include "AppInfo.xcconfig"
#include "Generated.xcconfig"
#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"
```

(Adjust the existing `#include` lines as scaffolded — the new `#include "AppInfo.xcconfig"` must be the first line. The original may not have the Pods line yet; that's added by `pod install` in Task 5.)

Edit `app/ios/Flutter/Release.xcconfig` identically — prepend `#include "AppInfo.xcconfig"`.

- [ ] **Step 3: Verify Xcode picks up the xcconfig**

Open Xcode workspace once to confirm settings resolve, then close:

```bash
open /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner.xcworkspace
# In Xcode: select Runner target → Signing & Capabilities → confirm:
#   - Team shows "Apple Developer Team (33HDFY8B9F)"
#   - Bundle Identifier: dev.littlelove.littlelove
#   - Display Name (under General): LittleLove
# Then quit Xcode.
```

If the Team field shows blank, Xcode hasn't logged into Court's Apple ID yet. Stop here and ask Court to open Xcode → Settings → Accounts → sign in with the Apple ID associated with team `33HDFY8B9F`. This is interactive — Court must do it (`!`-prefix `open -a Xcode` in his shell will work).

- [ ] **Step 4: Confirm pbxproj uses the xcconfig variables (no hardcoded bundle ID)**

```bash
grep -n "PRODUCT_BUNDLE_IDENTIFIER\|DEVELOPMENT_TEAM\|IPHONEOS_DEPLOYMENT_TARGET" /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner.xcodeproj/project.pbxproj | head -20
```

Expected: any `PRODUCT_BUNDLE_IDENTIFIER` entries in pbxproj resolve via `$(...)` from xcconfig, OR they hardcode `dev.littlelove.littlelove` (since we passed `--org dev.littlelove` to `flutter create`). If they hardcode an old/wrong value, sed-edit them:

```bash
sed -i '' 's|PRODUCT_BUNDLE_IDENTIFIER = com\.example\.[^;]*|PRODUCT_BUNDLE_IDENTIFIER = dev.littlelove.littlelove|g' \
  /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner.xcodeproj/project.pbxproj
```

Then re-grep to confirm all three configs (Debug/Release/Profile) show `dev.littlelove.littlelove`.

- [ ] **Step 5: Commit**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add app/ios/Flutter/AppInfo.xcconfig app/ios/Flutter/Debug.xcconfig app/ios/Flutter/Release.xcconfig app/ios/Runner.xcodeproj/project.pbxproj
git commit -m "chore(ios): align bundle ID + dev team with macOS via xcconfig"
```

---

## Task 3: Set Info.plist (display name + camera usage description)

**Files:**
- Modify: `app/ios/Runner/Info.plist`

- [ ] **Step 1: Add `NSCameraUsageDescription` and `CFBundleDisplayName`**

Open `app/ios/Runner/Info.plist`. Inside the top-level `<dict>`, add these two keys (alphabetize among siblings — Xcode auto-sorts on save anyway):

```xml
<key>CFBundleDisplayName</key>
<string>LittleLove</string>
<key>NSCameraUsageDescription</key>
<string>LittleLove uses the camera to scan a partner's pairing code.</string>
```

Use the Edit tool to insert after the existing `<key>CFBundleName</key><string>$(PRODUCT_NAME)</string>` block.

- [ ] **Step 2: Validate plist syntax**

```bash
plutil -lint /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner/Info.plist
```

Expected: `app/ios/Runner/Info.plist: OK`.

- [ ] **Step 3: Confirm the keys are present**

```bash
plutil -extract CFBundleDisplayName raw /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner/Info.plist
plutil -extract NSCameraUsageDescription raw /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner/Info.plist
```

Expected output:
```
LittleLove
LittleLove uses the camera to scan a partner's pairing code.
```

- [ ] **Step 4: Commit**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add app/ios/Runner/Info.plist
git commit -m "chore(ios): add display name and proactive camera-usage description"
```

---

## Task 4: Lock Podfile to iOS 13.0 with post_install matching macOS pattern

**Files:**
- Modify: `app/ios/Podfile`

- [ ] **Step 1: Set platform line and mirror macOS post_install pattern**

Open `app/ios/Podfile`. The Flutter scaffold provides a template with a commented `# platform :ios, '12.0'` line and a basic post_install. Edit so the relevant parts read:

```ruby
# Uncomment this line to define a global platform for your project
platform :ios, '13.0'

# CocoaPods analytics sends network stats synchronously affecting flutter build latency.
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. If you're running pod install manually, make sure \"flutter pub get\" is executed first"
  end

  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}. Try deleting Generated.xcconfig, then run \"flutter pub get\""
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
  target 'RunnerTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
```

This mirrors `app/macos/Runner/Podfile:1-42` adapted for iOS (`:osx` → `:ios`, `_macos_` → `_ios_`), plus a deployment-target enforcement for sub-pods to silence "deployment target lower than 13.0" warnings.

- [ ] **Step 2: Also bump Flutter scaffold's framework plist if needed**

```bash
plutil -replace MinimumOSVersion -string "13.0" /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Flutter/AppFrameworkInfo.plist
plutil -extract MinimumOSVersion raw /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Flutter/AppFrameworkInfo.plist
```

Expected: `13.0`.

- [ ] **Step 3: Commit (Podfile.lock will appear in Task 5)**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add app/ios/Podfile app/ios/Flutter/AppFrameworkInfo.plist
git commit -m "chore(ios): pin iOS 13.0 deployment target across Podfile and frameworks"
```

---

## Task 5: `pod install` and verify plugins resolve

**Files:**
- Create: `app/ios/Podfile.lock`, `app/ios/Pods/` (Pods/ is gitignored by Flutter's scaffolded .gitignore — verify, then only commit Podfile.lock)

- [ ] **Step 1: Run `pod install`**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS/app/ios
pod install
```

Expected: pods install for each plugin that has an iOS implementation (`flutter_secure_storage`, `path_provider_foundation`, `cryptography_flutter`-if-present, etc.). No errors.

If `pod install` errors with "Unable to find a specification for X", that plugin lacks an iOS implementation — **STOP, do not work around it, ask Court.**

If it warns about a deployment-target mismatch for a specific pod, the Task 4 post_install block should already coerce them; if a stubborn pod requires a higher minimum (e.g., 14.0), raise `IPHONEOS_DEPLOYMENT_TARGET` in `AppInfo.xcconfig`, `Podfile`, `AppFrameworkInfo.plist`, and the post_install block in one commit — keep all four in sync.

- [ ] **Step 2: Confirm Pods/ is gitignored**

```bash
git -C /Users/courtreeves/projects/little-love-WT-iOS check-ignore -v app/ios/Pods/Manifest.lock
```

Expected: a line like `app/ios/.gitignore:NN:Pods/   app/ios/Pods/Manifest.lock` — confirming the scaffolded `.gitignore` excludes `Pods/`. If not gitignored, append `Pods/` to `app/ios/.gitignore`.

- [ ] **Step 3: Commit Podfile.lock**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add app/ios/Podfile.lock
git commit -m "chore(ios): pod install — lock plugin pod versions"
```

---

## Task 6: Derive iOS app icons from existing master PNG

**Files:**
- Modify: `scripts/generate-app-icons.sh`
- Modify (regenerated): `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` and PNG files inside

The master PNG `app/assets/app-icon/littlelove-app-icon-master.png` (1024×1024 RGBA) already exists. We resize it for iOS, same as we already do for macOS and Windows. **This is not fabricating new icon art.**

- [ ] **Step 1: Extend `scripts/generate-app-icons.sh` with an iOS section**

Open `scripts/generate-app-icons.sh`. Add an `IOS_ICONSET` variable near the existing ones and a generation block. The file becomes:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT/app/assets/app-icon/littlelove-app-icon-master.png"
MAC_ICONSET="$ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
WIN_ICON="$ROOT/app/windows/runner/resources/app_icon.ico"
IOS_ICONSET="$ROOT/app/ios/Runner/Assets.xcassets/AppIcon.appiconset"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick is required: brew install imagemagick" >&2
  exit 1
fi

if [[ ! -f "$MASTER" ]]; then
  echo "Missing master icon: $MASTER" >&2
  exit 1
fi

# macOS
for size in 16 32 64 128 256 512 1024; do
  magick "$MASTER" -resize "${size}x${size}" "PNG32:$MAC_ICONSET/app_icon_${size}.png"
done

# Windows
magick "$MASTER" \
  -define icon:auto-resize=256,128,64,48,32,24,16 \
  "$WIN_ICON"

# iOS — Flutter's scaffolded AppIcon.appiconset uses these filenames/sizes.
# Sizes per Apple HIG (iPhone + iPad + App Store marketing icon).
if [[ -d "$IOS_ICONSET" ]]; then
  declare -a IOS_ICONS=(
    "Icon-App-20x20@1x.png:20"
    "Icon-App-20x20@2x.png:40"
    "Icon-App-20x20@3x.png:60"
    "Icon-App-29x29@1x.png:29"
    "Icon-App-29x29@2x.png:58"
    "Icon-App-29x29@3x.png:87"
    "Icon-App-40x40@1x.png:40"
    "Icon-App-40x40@2x.png:80"
    "Icon-App-40x40@3x.png:120"
    "Icon-App-60x60@2x.png:120"
    "Icon-App-60x60@3x.png:180"
    "Icon-App-76x76@1x.png:76"
    "Icon-App-76x76@2x.png:152"
    "Icon-App-83.5x83.5@2x.png:167"
    "Icon-App-1024x1024@1x.png:1024"
  )
  for entry in "${IOS_ICONS[@]}"; do
    name="${entry%%:*}"
    size="${entry##*:}"
    magick "$MASTER" -resize "${size}x${size}" -alpha remove -background white "PNG32:$IOS_ICONSET/$name"
  done
  echo "Generated iOS icons in $IOS_ICONSET"
else
  echo "Skipped iOS icons — $IOS_ICONSET does not exist (run flutter create --platforms=ios .)"
fi

echo "Generated macOS icons in $MAC_ICONSET"
echo "Generated Windows icon at $WIN_ICON"
```

**Why `-alpha remove -background white`:** iOS rejects icons with transparency; App Store Connect rejects the 1024 icon if it has an alpha channel. Flattening on white matches Apple's policy. The master PNG is RGBA so we must flatten.

- [ ] **Step 2: Run the script**

```bash
bash /Users/courtreeves/projects/little-love-WT-iOS/scripts/generate-app-icons.sh
```

Expected: `Generated iOS icons in .../AppIcon.appiconset`, `Generated macOS icons …`, `Generated Windows icon …`. No errors.

- [ ] **Step 3: Confirm filenames the Flutter scaffold expects**

The exact filename list above was the Flutter scaffold for iOS as of Flutter 3.44.x. Verify against actual scaffold:

```bash
cat /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json
```

If any `filename` referenced in `Contents.json` is missing from the generated set, add it to the `IOS_ICONS` array with the corresponding size derived from the `size` × `scale` fields (e.g., `"size":"60x60","scale":"3x"` → 180). Re-run the script.

- [ ] **Step 4: Verify no missing icons reported by Xcode**

```bash
plutil -lint /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json
ls /Users/courtreeves/projects/little-love-WT-iOS/app/ios/Runner/Assets.xcassets/AppIcon.appiconset/
```

Expected: `Contents.json: OK`, and every PNG listed in `Contents.json:filename` exists in the directory.

- [ ] **Step 5: Commit**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add scripts/generate-app-icons.sh app/ios/Runner/Assets.xcassets/AppIcon.appiconset
git commit -m "chore(ios): derive iOS app icons from existing master PNG"
```

---

## Task 7: Build for simulator and run

**Files:** none modified — verification only.

- [ ] **Step 1: Build the iOS app for simulator**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS/app
flutter build ios --simulator
```

Expected: `Building com.example...` → `✓ Built build/ios/iphonesimulator/Runner.app`. If it fails on `PhaseScriptExecution` related to a plugin's iOS build, **STOP** — that's a plugin iOS gap; flag to Court.

- [ ] **Step 2: Boot a simulator and run**

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
open -a Simulator
cd /Users/courtreeves/projects/little-love-WT-iOS/app
flutter devices | grep -i "iphone"
flutter run -d "iPhone 17"
```

Expected: app builds, installs to the simulator, and reaches the signup screen (the AuthGate that ships in WT-C). Confirm by screenshot or visual check.

If the app crashes on launch with a Keychain error, that's `flutter_secure_storage` failing because the simulator has no entitlement signing. Add an entitlements file in Task 8 if needed; otherwise document this as a known simulator-only quirk and verify on a real device.

- [ ] **Step 3: Quit the simulator session cleanly**

In the running `flutter run` terminal, type `q` to quit.

- [ ] **Step 4: Commit nothing — verification only. Move on.**

---

## Task 8: Add `scripts/ios-run.sh` helper

**Files:**
- Create: `scripts/ios-run.sh`

- [ ] **Step 1: Write the helper**

Create `scripts/ios-run.sh`:

```bash
#!/usr/bin/env bash
# scripts/ios-run.sh — launch LittleLove on an iOS simulator.
#
# Usage:
#   ./scripts/ios-run.sh                 # boots "iPhone 17" simulator and runs
#   ./scripts/ios-run.sh "iPhone 17 Pro" # uses a specific simulator name
#
# Optional env:
#   LLOVE_FIXTURES=demo  — seed the inbox with demo rooms
#   LLOVE_SERVER=…       — point at a dev API server
set -euo pipefail

DEVICE="${1:-iPhone 17}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

cd "$ROOT_DIR/app"
exec flutter run -d "$DEVICE" \
  ${LLOVE_FIXTURES:+--dart-define=LLOVE_FIXTURES="$LLOVE_FIXTURES"} \
  ${LLOVE_SERVER:+--dart-define=LLOVE_SERVER="$LLOVE_SERVER"}
```

- [ ] **Step 2: Make executable**

```bash
chmod +x /Users/courtreeves/projects/little-love-WT-iOS/scripts/ios-run.sh
```

- [ ] **Step 3: Smoke-test**

```bash
/Users/courtreeves/projects/little-love-WT-iOS/scripts/ios-run.sh
```

In the running session, type `q` to quit once the signup screen is visible.

- [ ] **Step 4: Commit**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add scripts/ios-run.sh
git commit -m "chore(ios): add ios-run.sh helper for simulator demos"
```

---

## Task 9: Document the physical-device release one-liner

**Files:**
- Modify: `app/README.md`

- [ ] **Step 1: Append an iOS section to `app/README.md`**

At the bottom of `app/README.md`, append:

```markdown
## iOS

Build and run on a simulator (no signing needed):

```sh
./scripts/ios-run.sh                  # boots iPhone 17 simulator and launches
# or
flutter build ios --simulator --no-codesign
```

Build a signed release IPA for a physical iPhone connected via USB or paired wirelessly:

```sh
cd app && flutter build ios --release
# then open ios/Runner.xcworkspace in Xcode, select your iPhone, and click Run.
```

The bundle ID (`dev.littlelove.littlelove`) and development team (`33HDFY8B9F`) are
pinned in `app/ios/Flutter/AppInfo.xcconfig`. Court holds the Apple Developer account.
TestFlight upload is a later task.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add app/README.md
git commit -m "docs(ios): document simulator + release one-liners"
```

---

## Task 10: Add `ios-build` CI job

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Append `ios-build` job**

Edit `.github/workflows/ci.yml`. After the `flutter:` job (which currently ends at line 56), add:

```yaml
  ios-build:
    runs-on: macos-latest
    defaults:
      run:
        working-directory: app
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: '3.44.x'
      - run: flutter pub get
      - name: pod install
        working-directory: app/ios
        run: pod install
      - name: build ios (simulator, no codesign)
        run: flutter build ios --simulator --no-codesign
```

**Why a separate job, not added to `flutter:`:** the existing `flutter:` job runs on `ubuntu-latest`, which cannot build iOS. Splitting keeps the cheap Linux job fast and pushes the slower macOS runner only onto iOS.

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('/Users/courtreeves/projects/little-love-WT-iOS/.github/workflows/ci.yml'))"
```

Expected: exits 0 with no output.

- [ ] **Step 3: Commit**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git add .github/workflows/ci.yml
git commit -m "ci(ios): add ios-build job on macos-latest (simulator, no codesign)"
```

---

## Task 11: Open PR

**Files:** none — git/GitHub only.

- [ ] **Step 1: Push the branch**

```bash
cd /Users/courtreeves/projects/little-love-WT-iOS
git push -u origin feat/ios-build-target
```

- [ ] **Step 2: Open PR against `main`**

```bash
gh pr create --base main --title "feat(ios): add iOS build target (WT-iOS)" --body "$(cat <<'EOF'
## Summary

- Scaffolds `app/ios/` for the existing Flutter app (signup + inbox shell).
- Aligns iOS bundle ID (`dev.littlelove.littlelove`) and dev team (`33HDFY8B9F`) with the existing macOS Xcode config via a shared-pattern `AppInfo.xcconfig`.
- Adds `NSCameraUsageDescription` proactively so WT-D's `mobile_scanner` merge doesn't break iOS.
- Derives iOS app icons from the existing 1024×1024 master PNG (no new art).
- Adds `scripts/ios-run.sh` and a CI `ios-build` job on `macos-latest`.

## Test plan

- [ ] CI `ios-build` job passes (`flutter build ios --simulator --no-codesign`).
- [ ] Existing CI `rust` and `flutter` jobs still pass.
- [ ] Court runs `./scripts/ios-run.sh` locally and confirms the signup screen renders.
- [ ] Court runs `flutter build ios --release` and side-loads to his iPhone; signup screen renders on device.

## Out of scope

- TestFlight upload (later task).
- Refactoring `app/lib/identity/account_local.dart` to use `path_provider` instead of `$HOME` (works on iOS sandbox today; revisit if it becomes a problem).
EOF
)"
```

- [ ] **Step 3: Confirm PR URL**

Capture the URL `gh pr create` returns and post it back to Court. **Do not merge — Court verifies on his iPhone.**

---

## Self-Review

**Spec coverage check:**
- [x] Scaffold/refresh `app/ios/` → Task 1
- [x] Bundle ID matches macOS → Task 2
- [x] DEVELOPMENT_TEAM in Xcode signing config → Task 2
- [x] `pod install` from `app/ios/` → Task 5
- [x] `NSCameraUsageDescription` proactively in Info.plist → Task 3
- [x] iOS deployment target matches Flutter stable recommendation (13.0) → Task 4
- [x] `flutter build ios --simulator` succeeds → Task 7 step 1
- [x] `flutter run -d <simulator>` reaches signup screen → Task 7 step 2
- [x] Document `flutter build ios --release` one-liner → Task 9
- [x] `scripts/ios-run.sh` for future demos → Task 8
- [x] CI `ios-build` job on macOS runner, no signing → Task 10
- [x] Open PR against main, do not merge → Task 11
- [x] Asset pack discipline (no fabricated icons — derive from existing master PNG) → Task 6

**Stop conditions documented:**
- [x] Signing prompts beyond known team → Task 2 step 3
- [x] Plugin without iOS implementation → Task 5 step 1
- [x] Xcode license / interactive prompts → Pre-flight + Task 2 step 3

**Type/name consistency:** xcconfig names (`PRODUCT_BUNDLE_IDENTIFIER`, `DEVELOPMENT_TEAM`, `IPHONEOS_DEPLOYMENT_TARGET`), helper script paths (`scripts/ios-run.sh`), icon filenames (Apple's `Icon-App-*` scheme), and Podfile flutter helper functions (`flutter_ios_podfile_setup`, `flutter_install_all_ios_pods`, `flutter_additional_ios_build_settings`) are consistent across all tasks.

**Placeholder scan:** None — every step has either exact code, an exact command with expected output, or both.
