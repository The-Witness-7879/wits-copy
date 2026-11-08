#!/usr/bin/env bash
# Build a local ad-hoc Release DMG and a signed Sparkle appcast. Never publishes.
# Usage: ./scripts/release.sh   (set DEVELOPER_DIR if xcode-select points at the Command Line Tools)
# Requires Xcode, Python 3, and Sparkle's key in the login Keychain. Provision it
# once with SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys (no export).
# Optional SPARKLE_ACCOUNT selects an existing Keychain account (default ed25519).
# The output stays under lab/releases/<marketing-version>-<build-number>/.
# This is NOT Developer ID signed or notarized. First launch needs Gatekeeper
# approval; every new ad-hoc binary needs Accessibility permission again.
set -euo pipefail
if [ "$#" != 0 ]; then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DERIVED="$ROOT/lab/.derived-release"
PREFIX='https://github.com/The-Witness-7879/wits-copy/releases/latest/download/'
ACCOUNT="${SPARKLE_ACCOUNT:-ed25519}"
for tool in xcodebuild xcrun python3 codesign hdiutil ditto shasum; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done
xcrun --find swift >/dev/null
mkdir -p "$DERIVED" "$ROOT/lab/releases"
touch "$DERIVED/.metadata_never_index" "$ROOT/lab/releases/.metadata_never_index"
WORK="$(mktemp -d "$ROOT/lab/release-work.XXXXXX")"
export TMPDIR="$WORK/tmp/"
mkdir -p "$TMPDIR" "$WORK/products/updates" "$WORK/stage" "$WORK/mount"
MOUNTED=0
cleanup() {
  local status=$?
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach "$WORK/mount" >/dev/null || true
  fi
  if [ "$status" != 0 ]; then
    printf 'Release failed (exit %s); diagnostics retained: %s\n' "$status" "$WORK" >&2
  fi
}
trap cleanup EXIT

# Clean products before building: removed frameworks/resources must not leak in.
set +e
nice -n 10 xcodebuild clean build \
  -project WitsCopy.xcodeproj -scheme WitsCopy -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  -jobs 2 -parallel-testing-enabled NO CLANG_ENABLE_CODE_COVERAGE=NO \
  SWIFT_COMPILATION_MODE=wholemodule SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=NO \
  2>&1 | tee "$WORK/products/build.log"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
printf '%s\n' "$BUILD_STATUS" > "$WORK/products/build.exitcode"
[ "$BUILD_STATUS" = 0 ] || exit "$BUILD_STATUS"
TOOLS="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
# Only generate_appcast reads the private key, once per release. Public-key
# verification below must not use Keychain or prompt for the login password.
for tool in generate_appcast; do
  [ -x "$TOOLS/$tool" ] || { printf 'Missing Sparkle tool: %s\n' "$tool" >&2; exit 1; }
done
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' WitsCopy/Info.plist)"
APP="$WORK/stage/WitsCopy.app"
ditto "$DERIVED/Build/Products/Release/WitsCopy.app" "$APP"
export APP PUBLIC_KEY
python3 - <<'PY'
import base64, os, pathlib, plistlib
app = pathlib.Path(os.environ['APP'])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleDisplayName'] == "Wit's Copy"
assert info['SUFeedURL'] == 'https://github.com/The-Witness-7879/wits-copy/releases/latest/download/appcast.xml'
assert info['SUPublicEDKey'] == os.environ['PUBLIC_KEY'], 'Keychain public key differs from embedded key'
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
assert info['SUEnableAutomaticChecks'] and info['SUScheduledCheckInterval'] == 86400
assert info['SUVerifyUpdateBeforeExtraction'] and info['SURequireSignedFeed']
assert not info['SUAutomaticallyUpdate'] and not info['SUEnableSystemProfiling']
PY
python3 scripts/adhoc-sign.py "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
case "$VERSION-$BUILD" in *[!0-9.-]*) printf 'Unsafe version/build\n' >&2; exit 1;; esac
OUTPUT="$ROOT/lab/releases/$VERSION-$BUILD"
[ ! -e "$OUTPUT" ] || { printf 'Refusing to overwrite existing release: %s\n' "$OUTPUT" >&2; exit 1; }
DMG_NAME="WitsCopy-$VERSION-$BUILD.dmg"
DMG="$WORK/products/updates/$DMG_NAME"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -srcfolder "$WORK/stage" -volname "Wit's Copy" -fs APFS -format ULFO -nospotlight "$DMG"
hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$WORK/mount" "$DMG"
MOUNTED=1
[ "$(readlink "$WORK/mount/Applications")" = /Applications ]
codesign --verify --deep --strict --verbose=2 "$WORK/mount/WitsCopy.app"
# Mount verification must see the exact same release identity and public key.
cmp "$APP/Contents/Info.plist" "$WORK/mount/WitsCopy.app/Contents/Info.plist"
hdiutil detach "$WORK/mount"
MOUNTED=0
"$TOOLS/generate_appcast" --account "$ACCOUNT" --download-url-prefix "$PREFIX" \
  --maximum-deltas 0 "$WORK/products/updates"
APPCAST="$WORK/products/updates/appcast.xml"
export DMG APPCAST VERSION BUILD PREFIX
SIGNATURE="$(python3 - <<'PY'
import base64, os, pathlib, re, xml.etree.ElementTree as ET
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
feed_path = pathlib.Path(os.environ['APPCAST'])
root = ET.parse(feed_path).getroot()
items = root.findall('./channel/item')
assert len(items) == 1, 'Expected exactly this release in fresh appcast'
item = items[0]
assert item.findtext('sparkle:version', namespaces=ns) == os.environ['BUILD']
assert item.findtext('sparkle:shortVersionString', namespaces=ns) == os.environ['VERSION']
enclosure = item.find('enclosure')
assert enclosure is not None
assert enclosure.attrib['url'] == os.environ['PREFIX'] + pathlib.Path(os.environ['DMG']).name
assert int(enclosure.attrib['length']) == pathlib.Path(os.environ['DMG']).stat().st_size
signature = enclosure.attrib['{' + ns['sparkle'] + '}edSignature']
assert len(base64.b64decode(signature, validate=True)) == 64
feed_signature = re.search(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength:', feed_path.read_bytes())
assert feed_signature is not None and len(base64.b64decode(feed_signature.group(1), validate=True)) == 64
print(signature)
PY
)"
# No sign_update --verify here: even verification can trigger Keychain ACL prompts.
# The independent public-key check below proves the DMG signature instead.
# Independently verify the DMG against the *embedded* public key (not the Keychain).
# No private material is read by this verifier.
nice -n 10 xcrun swift -module-cache-path "$DERIVED/ModuleCache.noindex" - "$DMG" "$PUBLIC_KEY" "$SIGNATURE" <<'SWIFT'
import CryptoKit
import Foundation
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[2])!)
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
guard key.isValidSignature(Data(base64Encoded: args[3])!, for: data) else {
  fatalError("DMG does not match embedded SUPublicEDKey")
}
print("DMG Ed25519 signature verified independently against embedded public key")
SWIFT
(
  cd "$WORK/products/updates"
  shasum -a 256 "$DMG_NAME" appcast.xml > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
# Preserve the signed app and symbols alongside, not inside the update archive directory.
ditto "$APP" "$WORK/products/WitsCopy.app"
if [ -d "$DERIVED/Build/Products/Release/WitsCopy.app.dSYM" ]; then
  ditto "$DERIVED/Build/Products/Release/WitsCopy.app.dSYM" "$WORK/products/WitsCopy.app.dSYM"
fi
mv "$WORK/products" "$OUTPUT"
# Read back the promoted exact targets; only then report success.
codesign --verify --deep --strict "$OUTPUT/WitsCopy.app"
(cd "$OUTPUT/updates" && shasum -a 256 -c SHA256SUMS)
printf 'Release verified (ad-hoc, not notarized):\n  %s\n  %s\n  %s\n' \
  "$OUTPUT/updates/$DMG_NAME" "$OUTPUT/updates/appcast.xml" "$OUTPUT/updates/SHA256SUMS"
rm -rf "$WORK"
