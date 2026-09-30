#!/bin/sh
# Runner build phase "Generate WebRTC dSYM" (see project.pbxproj).
#
# flutter_webrtc pulls the WebRTC-SDK pod, whose prebuilt WebRTC.xcframework
# ships no dSYM. Without one, every App Store Connect upload warns "Upload
# Symbols Failed" and Apple's crash reports can't symbolicate frames inside
# WebRTC (native call code). dsymutil on the embedded binary emits a dSYM with
# the matching UUID into DWARF_DSYM_FOLDER_PATH, where the archive collects it
# (the same place CocoaPods installs dSYMs that pods do ship).
#
# The binary's debug info is stripped upstream, so this dSYM carries exported
# symbols only: function names, no file/line.
#
# MUST run after "[CP] Embed Pods Frameworks", which copies the framework into
# the app. No-op for builds that make no dSYMs (Debug) and when the framework
# isn't embedded (flutter_webrtc removed).

[ "$DEBUG_INFORMATION_FORMAT" = "dwarf-with-dsym" ] || exit 0

binary="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/WebRTC.framework/WebRTC"
[ -f "$binary" ] || exit 0

# A missing dSYM only costs crash symbolication, so a failure here warns
# instead of failing the release build. Fold dsymutil's output into one
# warning line with its "error:" prefixes removed: Xcode fails the build on
# any "error:" a script phase prints, even when it exits 0.
if ! out=$(xcrun dsymutil "$binary" -o "$DWARF_DSYM_FOLDER_PATH/WebRTC.framework.dSYM" 2>&1); then
  echo "warning: couldn't generate WebRTC.framework.dSYM ($(printf '%s' "$out" | sed 's/error: //g' | tr '\n' ' '))"
  exit 0
fi

# dsymutil always says "no debug symbols in executable" for this stripped
# binary. Drop that expected line so Xcode doesn't raise it as a build warning
# on every release build; pass anything else through.
printf '%s\n' "$out" | grep -v -e 'no debug symbols in executable' -e '^$' || true
