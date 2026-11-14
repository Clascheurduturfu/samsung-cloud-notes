#!/usr/bin/env python3
"""Build a local beta from the owner's Samsung Notes APK; never fetch vendor APKs."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import zipfile
from patch import APK_SHA256, BETA_VERSION, patch

APKTOOL_SHA256 = "dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
REPO = Path(__file__).resolve().parent.parent


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def run(arguments: list[str], cwd: Path | None = None) -> None:
    subprocess.run(arguments, cwd=cwd, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--apktool", type=Path, required=True, help="Official Apktool 3.0.3 JAR")
    parser.add_argument("--java-home", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--stage", type=Path, required=True, help="New directory outside the source checkout")
    parser.add_argument("--bridge", action="store_true", help="Include independent account UI and selectable native cloud sync")
    parser.add_argument("--keystore", type=Path)
    parser.add_argument("--key-alias", default="scnotes-native-beta")
    parser.add_argument("--password-env", default="SCNP_PASS", help="Keystore password environment variable; never a literal password")
    args = parser.parse_args()
    original, apktool, stage = args.apk.resolve(), args.apktool.resolve(), args.stage.resolve()
    if stage.is_relative_to(REPO):
        parser.error("Use a build stage outside the source checkout to isolate Samsung binaries.")
    if stage.exists():
        parser.error("Stage already exists; choose a new directory. Existing files are never removed.")
    if sha256(original) != APK_SHA256:
        parser.error("Unsupported Samsung Notes APK hash; this profile supports only the audited 4.4.48.15 ARM APK.")
    if sha256(apktool) != APKTOOL_SHA256:
        parser.error("Apktool JAR hash does not match the pinned official 3.0.3 release.")
    if args.keystore and not os.environ.get(args.password_env):
        parser.error(f"Set {args.password_env} before signing.")
    stage.mkdir(parents=True)
    exe = ".exe" if os.name == "nt" else ""
    java = str(args.java_home / "bin" / ("java" + exe))
    tools = args.sdk / "build-tools/37.0.0"
    environment = os.environ.copy()
    environment["JAVA_HOME"] = str(args.java_home)
    environment["ANDROID_HOME"] = str(args.sdk)
    decoded = stage / "decoded"
    run([java, "-Xmx5G", "-jar", str(apktool), "d", "--no-debug-info", "-j", "6", "-o", str(decoded), str(original)])
    patch(decoded, original, args.bridge)
    if args.bridge:
        wrapper = REPO / "android" / ("gradlew.bat" if os.name == "nt" else "gradlew")
        subprocess.run([str(wrapper), ":native-bridge:assembleRelease", "-PnativeUploadProbeUUID=", "--console=plain"], cwd=REPO / "android", env=environment, check=True)
        jars = []
        for module in ("auth-core", "native-bridge"):
            aar = REPO / f"android/{module}/build/outputs/aar/{module}-release.aar"
            target = stage / f"{module}.jar"
            with zipfile.ZipFile(aar) as archive:
                target.write_bytes(archive.read("classes.jar"))
            jars.append(str(target))
        dex = stage / "bridge-dex"
        dex.mkdir()
        platform = args.sdk / "platforms/android-37/android.jar"
        if not platform.exists():
            platform = args.sdk / "platforms/android-37.0/android.jar"
        run([java, "-cp", str(tools / "lib/d8.jar"), "com.android.tools.r8.D8", "--release", "--min-api", "29",
             "--lib", str(platform), "--output", str(dex), *jars])
        if not (dex / "classes.dex").exists() or (dex / "classes2.dex").exists():
            raise RuntimeError("Unexpected bridge DEX layout")
    unsigned = stage / "native-unsigned.apk"
    run([java, "-Xmx5G", "-jar", str(apktool), "b", "-j", "6", "-o", str(unsigned), str(decoded)])
    if args.bridge:
        injected = stage / "native-bridge-unsigned.apk"
        with zipfile.ZipFile(unsigned) as source, zipfile.ZipFile(injected, "w") as target:
            for entry in source.infolist():
                target.writestr(entry, source.read(entry.filename))
            if "classes14.dex" in source.namelist():
                raise RuntimeError("classes14.dex collision")
            target.write(dex / "classes.dex", "classes14.dex", compress_type=zipfile.ZIP_DEFLATED)
        unsigned = injected
    aligned = stage / "SamsungNotes-native-beta.3-unsigned.apk"
    run([str(tools / ("zipalign" + exe)), "-P", "16", "4", str(unsigned), str(aligned)])
    output = aligned
    if args.keystore:
        output = stage / "SamsungNotes-native-beta.3.apk"
        run([java, "-jar", str(tools / "lib/apksigner.jar"), "sign", "--ks", str(args.keystore), "--ks-key-alias", args.key_alias,
             "--ks-pass", "env:" + args.password_env, "--v4-signing-enabled", "false", "--out", str(output), str(aligned)])
        run([java, "-jar", str(tools / "lib/apksigner.jar"), "verify", str(output)])
    (stage / "build-manifest.json").write_text(json.dumps({
        "nativeVersion": BETA_VERSION, "bridgeVersion": re.search(r'const val version = "([^"]+)"', (REPO / "android/native-bridge/src/main/java/local/samsungcloudnotes/nativebridge/Bridge.kt").read_text(encoding="utf-8"))[1], "originalSha256": APK_SHA256,
        "apktoolSha256": APKTOOL_SHA256, "bridge": args.bridge, "nativeSyncMode": "selectable" if args.bridge else "disabled", "uploadProbeEnabled": False,
        "output": output.name, "outputSha256": sha256(output), "signed": bool(args.keystore),
    }, indent=2) + "\n", encoding="utf-8")
    print(f"Local beta: {output}")


if __name__ == "__main__":
    main()
