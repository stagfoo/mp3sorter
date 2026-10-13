#!/usr/bin/env bash
# The tag is exactly the app's version, with no "v" and no commit suffix, so it
# matches the versionName inside the APK. Obtainium compares the version string
# a release advertises against the version Android reports for the installed
# app, and can only do that when the two are the same shape.
set -euo pipefail

# Say which step failed and how. Piping this script through `tail` hides the
# error, and a silent abort before the build is how a release ends up carrying
# the previous version's APK — publish only ever from here, never by hand
# afterwards, or the version check below is skipped along with everything else.
trap 'status=$?; if [ $status -ne 0 ]; then
  echo "" >&2
  echo "!! release.sh FAILED at line $LINENO (exit $status)." >&2
  echo "!! Nothing was published. Do not finish this by hand: the APK in" >&2
  echo "!! build/ may be from an earlier version, and publishing it skips" >&2
  echo "!! the check that would have caught that." >&2
fi' EXIT

cd "$(dirname "$0")/.."

app_name=$(basename "$(pwd)")

current=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}')
current_version=${current%%+*}
current_build=${current##*+}

# Every release gets its own version. Shipping the same version twice leaves
# Obtainium with nothing to compare, and leaves Android with no reason to treat
# the APK as an update.
major=$(echo "$current_version" | cut -d. -f1)
minor=$(echo "$current_version" | cut -d. -f2)
patch=$(echo "$current_version" | cut -d. -f3)
next_version="$major.$minor.$((patch + 1))"
next_build=$((current_build + 1))
tag="$next_version"

# arm64-only, not the universal multi-ABI APK: arm64-v8a covers every real
# Android device from the last ~8 years, and this is a personal sideload.
apk_path="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"

echo "==> $app_name $current_version -> $next_version"

if gh release view "$tag" >/dev/null 2>&1; then
  echo "!! Release $tag already exists; bump past it or delete it first." >&2
  exit 1
fi

sed -i "s/^version: .*/version: $next_version+$next_build/" pubspec.yaml

flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64 --split-per-abi

# Everything, not just the pubspec. Committing the version alone leaves the
# source of the release only in the working tree: the APK was built from it, so
# what shipped and what the repo says are different things, and a stray git
# checkout could destroy work that has already gone out.
git add -A
git commit -m "Release $next_version"

# gh release create --target takes a commit the remote already has; without
# this the whole build runs and then fails with "target_commitish is invalid".
git push origin HEAD

# The APK must have been built from the bumped pubspec, not from whatever was
# lying in build/ beforehand. Releasing a stale artefact ships the previous
# version under a new tag: Android sees an unchanged versionCode and declines
# the install, and the release quietly contains none of its own changes.
if command -v aapt2 >/dev/null 2>&1; then
  aapt2_bin=aapt2
else
  aapt2_bin=$(ls -d "${ANDROID_HOME:-$HOME/development/android-sdk}"/build-tools/*/aapt2 2>/dev/null | tail -1 || true)
fi
if [ -n "${aapt2_bin:-}" ] && [ -x "${aapt2_bin}" ]; then
  # Captured whole, then matched. Piping aapt2 into head kills aapt2 with
  # SIGPIPE the moment head has its line, and pipefail turns that into a failed
  # release — the guard against shipping a stale APK itself stopping the
  # publish, after a build that had gone perfectly well.
  badging=$("$aapt2_bin" dump badging "$apk_path")
  built=$(printf '%s\n' "$badging" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | sed -n 1p)
  if [ "$built" != "$next_version" ]; then
    echo "!! APK says version $built but the release is $next_version." >&2
    echo "!! That is a stale build; it would ship the previous version." >&2
    exit 1
  fi
  echo "==> APK verified as $built"
else
  echo "!! aapt2 not found; cannot verify the APK matches $next_version." >&2
fi

gh release create "$tag" "$apk_path" \
  --title "$app_name $next_version" \
  --notes "$(git log -1 --pretty=%s)" \
  --target "$(git rev-parse HEAD)"

gh release view "$tag" --json url --jq .url
