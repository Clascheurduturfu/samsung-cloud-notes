#!/usr/bin/env python3
"""Package an already signed universal Mac app without private build material."""
from __future__ import annotations
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import zipfile


def package(app: pathlib.Path, output: pathlib.Path, previous: pathlib.Path | None = None) -> pathlib.Path:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["SamsungCloudNotesVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?", version):
        raise ValueError("Unsupported release version")
    if info["CFBundleIdentifier"] != "local.samsung-cloud-notes":
        raise ValueError("Wrong app identity")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if previous is not None:
        requirement = subprocess.run(["codesign", "-d", "-r-", str(previous)], capture_output=True, text=True, check=True)
        match = re.search(r"designated => (.+)", requirement.stdout + requirement.stderr)
        if not match:
            raise ValueError("Previous app has no publisher requirement")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + match[1], str(app)], check=True)
        helper = pathlib.Path("Contents/Resources/CredentialStore.app/Contents/MacOS/CredentialStore")
        if (app / helper).read_bytes() != (previous / helper).read_bytes():
            raise ValueError("The preserved credential helper changed")
    arches = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/SamsungCloudNotes")], text=True).split()
    if not {"arm64", "x86_64"}.issubset(arches):
        raise ValueError("Release packages must support both Mac architectures")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"SamsungCloudNotes-{version}-macOS.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for item in sorted(app.rglob("*")):
            if item.is_symlink():
                raise ValueError("This bundle contract has no symbolic links")
            if item.is_file():
                z.write(item, "Samsung Cloud Notes.app/" + item.relative_to(app).as_posix())
    data = archive.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    (output / "SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    (output / "macos-release.json").write_text(json.dumps({
        "app": "samsung-cloud-notes-macos", "version": version, "tag": "v" + version,
        "asset": archive.name, "bytes": len(data), "sha256": digest,
        "bundleID": info["CFBundleIdentifier"], "architectures": sorted(arches),
    }, indent=2) + "\n", encoding="utf-8")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, default=pathlib.Path("dist/Samsung Cloud Notes.app"))
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist/release-macos"))
    parser.add_argument("--trusted-previous-app", type=pathlib.Path)
    args = parser.parse_args()
    print(package(args.app, args.output, args.trusted_previous_app))
