#!/usr/bin/env python3
"""Explicit, transactional Mac release publication. Never invoked by normal pushes."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess

MARKER = "<!-- samsung-cloud-notes:update-channel=preview -->"


def api(path, method="GET", body=None, binary=False):
    command = ["gh", "api", path, "--method", method]
    if binary:
        command += ["-H", "Accept: application/octet-stream"]
    if body is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(body).encode() if body is not None else None, stdout=subprocess.PIPE, check=True)
    return result.stdout if binary else json.loads(result.stdout or b"null")


def preview_records(releases, keep_id):
    """Only this app's marked Preview stream; never Stable, drafts or other apps."""
    return [r for r in releases if r["id"] != keep_id and not r.get("draft") and r.get("prerelease")
            and MARKER in (r.get("body") or "") and re.fullmatch(r"v\d+\.\d+\.\d+-(?:alpha|beta|rc)\.\d+", r.get("tag_name", ""))
            and any(a.get("name", "").startswith("SamsungCloudNotes-") and a.get("name", "").endswith("-macOS.zip") for a in r.get("assets", []))]


def version_key(version):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?", version)
    if not match:
        raise ValueError("Unsupported publication version")
    major, minor, patch, stage, iteration = match.groups()
    return int(major), int(minor), int(patch), {"alpha": 0, "beta": 1, "rc": 2, None: 3}[stage], int(iteration or 0)


def publish(repository, channel, commit, directory):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Invalid repository or exact commit")
    manifest = json.loads((directory / "macos-release.json").read_text())
    version, tag = manifest["version"], manifest["tag"]
    version_key(version)
    if manifest.get("app") != "samsung-cloud-notes-macos" or tag != "v" + version or (("-" in version) != (channel == "preview")):
        raise ValueError("Package version and channel disagree")
    archive = directory / manifest["asset"]
    if archive.name != f"SamsungCloudNotes-{version}-macOS.zip" or hashlib.sha256(archive.read_bytes()).hexdigest() != manifest["sha256"]:
        raise ValueError("Package integrity mismatch")
    root = f"repos/{repository}"
    releases = api(root + "/releases?per_page=100")
    if channel == "preview" and any(version_key(r["tag_name"]) >= version_key(version) for r in preview_records(releases, -1)):
        raise ValueError("Advance the Preview version before publication")
    existing = [r for r in releases if r["tag_name"] == tag]
    if any(not r["draft"] for r in existing):
        raise ValueError("Version is already published; advance the version instead of replacing bytes")
    # A retained tag must resolve to the reviewed build, never a different commit.
    try:
        api(root + "/git/refs", "POST", {"ref": "refs/tags/" + tag, "sha": commit})
    except subprocess.CalledProcessError:
        reference = api(root + "/git/ref/tags/" + tag)["object"]
        for _ in range(4):
            if reference["type"] != "tag":
                break
            reference = api(root + "/git/tags/" + reference["sha"])["object"]
        if reference["type"] != "commit" or reference["sha"] != commit:
            raise ValueError("Existing tag does not point to the reviewed commit")
    notes = f"Samsung Cloud Notes for macOS {version}\n\n" + (MARKER + "\n\n" if channel == "preview" else "")
    notes += "Universal arm64/x86_64 build. See CHANGELOG.md and docs/validation.md at this tag.\n"
    if existing:
        release = existing[0]
        if release["target_commitish"] != commit or bool(release["prerelease"]) != (channel == "preview"):
            raise ValueError("An incompatible draft already exists")
    else:
        release = api(root + "/releases", "POST", {"tag_name": tag, "target_commitish": commit, "name": f"Samsung Cloud Notes {version}",
            "body": notes, "draft": True, "prerelease": channel == "preview", "make_latest": "false"})
    files = [archive, directory / "SHA256SUMS.txt", directory / "macos-release.json"]
    for file in files:
        found = [a for a in release.get("assets", []) if a["name"] == file.name]
        if not found:
            subprocess.run(["gh", "release", "upload", tag, str(file), "--repo", repository], check=True)
        release = api(root + f"/releases/{release['id']}")
        asset = next(a for a in release["assets"] if a["name"] == file.name)
        expected = hashlib.sha256(file.read_bytes()).hexdigest()
        downloaded = api(root + f"/releases/assets/{asset['id']}", binary=True)
        if len(downloaded) != file.stat().st_size or hashlib.sha256(downloaded).hexdigest() != expected or asset.get("digest") != "sha256:" + expected:
            raise ValueError("Uploaded release asset failed downloaded size/digest verification; draft retained")
    release = api(root + f"/releases/{release['id']}", "PATCH", {"draft": False, "make_latest": "false" if channel == "preview" else "true"})
    fresh = api(root + "/releases?per_page=100")
    verified = next((r for r in fresh if r["id"] == release["id"] and not r["draft"]), None)
    if verified is None or bool(verified["prerelease"]) != (channel == "preview") or not any(a["name"] == archive.name and a.get("digest") == "sha256:"+manifest["sha256"] for a in verified["assets"]):
        raise ValueError("Published release could not be rediscovered; older Preview records retained")
    print("Published and verified:", verified["html_url"])
    if channel == "preview":
        for old in preview_records(fresh, release["id"]):
            try:
                api(root + f"/releases/{old['id']}", "DELETE")  # Keep all underlying Git tags.
            except subprocess.CalledProcessError:
                print("Preview cleanup failed for release record", old["id"], "; new release remains published")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--repository", required=True)
    p.add_argument("--channel", choices=["stable", "preview"], required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--directory", type=pathlib.Path, default=pathlib.Path("dist/release-macos"))
    a = p.parse_args()
    publish(a.repository, a.channel, a.commit, a.directory)
