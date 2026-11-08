#!/usr/bin/env python3
"""Ad-hoc sign a built WitsCopy.app inside-out and verify it.

Usage: scripts/adhoc-sign.py <path/to/WitsCopy.app>

Signs every Mach-O file first, then every enclosing code bundle deepest-first,
then the app itself with the project entitlements. `codesign --deep` is not used
for signing: explicit inside-out signing also covers helper tools, XPC services,
nested apps and frameworks. The result is not Developer ID signed or notarized.
"""
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTITLEMENTS = ROOT / "WitsCopy" / "WitsCopy.entitlements"
MACHO = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
BUNDLES = {".app", ".xpc", ".framework", ".bundle", ".appex"}


def codesign(*args: str) -> None:
    subprocess.run(["codesign", *args], check=True)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    app = pathlib.Path(sys.argv[1])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "local.thewitness.WitsCopy"
    assert info["CFBundleExecutable"] == "WitsCopy"
    assert not list(app.rglob("*.xctest")), "release must not contain test bundles"

    nested = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    nested.append(path)
        elif path.suffix in BUNDLES:
            nested.append(path)
    nested.sort(key=lambda path: (-len(path.parts), str(path)))

    common = ["--force", "--sign", "-", "--timestamp=none", "--options", "0"]
    for path in nested:
        codesign(*common, "--preserve-metadata=entitlements", str(path))
    codesign(*common, "--entitlements", str(ENTITLEMENTS), str(app))
    for path in nested + [app]:
        codesign("--verify", "--strict", str(path))
    codesign("--verify", "--deep", "--strict", str(app))
    print(f"signed and verified: {len(nested)} nested code objects + app "
          f"({info['CFBundleShortVersionString']} build {info['CFBundleVersion']})")


if __name__ == "__main__":
    main()
