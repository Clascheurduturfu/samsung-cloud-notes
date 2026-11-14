#!/usr/bin/env python3
"""Patch an owner-supplied, hash-pinned Samsung Notes decode. No vendor files ship here."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET
from hooks import compatibility_hooks, native_hooks

APK_SHA256 = "484d3dd599355789508034ba90af9a35e09f81532564a992c131710632a467ce"
BASE_VERSION = "4.4.48.15"
BETA_VERSION = "4.4.48.15-native-beta.3"


def add_standard_document_filter(manifest: str) -> str:
    name = "com.samsung.android.support.senl.nt.app.trigger.DocOpenTriggerActivity"
    pattern = re.compile(r'(<activity\b[^>]*android:name="' + re.escape(name) + r'"[^>]*>)(.*?)(</activity>)', re.S)
    addition = r'''
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:scheme="content" android:host="*" android:mimeType="application/octet-stream" android:pathPattern=".*\\.sdocx" />
            </intent-filter>
'''
    result, count = pattern.subn(lambda m: m[1] + m[2] + addition + m[3], manifest)
    if count != 1:
        raise ValueError("Unsupported input: native document-open activity differs")
    return result


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f"Unsupported input: expected one occurrence of {before!r}")
    return text.replace(before, after, 1)


def patch(decoded: Path, original: Path, bridge: bool = False) -> None:
    with original.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != APK_SHA256:
        raise ValueError("Unsupported APK: original Samsung Notes SHA-256 differs from the tested profile.")
    shim_source = Path(__file__).parent / "compat"
    shim_target = decoded / "smali_classes13"
    if shim_target.exists():
        raise ValueError("Unsupported input: classes13 already exists.")
    changes = compatibility_hooks(decoded)
    if bridge:
        changes.update(native_hooks(decoded))
        settings = decoded / "res/xml/settings_main_preference.xml"
        xml = settings.read_text(encoding="utf-8")
        anchor = '<androidx.preference.PreferenceCategory android:title="@string/settings_general_category" android:key="settings_general_category">'
        entry = '''
        <androidx.preference.Preference android:title="Samsung Cloud" android:summary="Account, sync and offline notes" android:key="settings_cloud_beta">
            <intent android:targetPackage="com.samsung.android.app.notes" android:targetClass="local.samsungcloudnotes.nativebridge.AccountActivity" />
        </androidx.preference.Preference>'''
        changes[settings] = replace_once(xml, anchor, anchor + entry)
    manifest_file = decoded / "AndroidManifest.xml"
    manifest = manifest_file.read_text(encoding="utf-8")
    manifest = add_standard_document_filter(manifest)
    manifest = replace_once(manifest,
        '<uses-library android:name="com.samsung.device" android:required="true"/>',
        '<uses-library android:name="com.samsung.device" android:required="false"/>')
    # This provider exposes settings to Samsung's Settings search app. Its
    # onCreate directly reads Configuration.semDesktopModeEnabled on AOSP.
    provider = "com.samsung.android.support.senl.nt.app.settings.externalsearch.SettingsSearchProvider"
    pattern = rf'<provider\b[^>]*android:name="{re.escape(provider)}"[^>]*>'
    matches = list(re.finditer(pattern, manifest))
    if len(matches) != 1:
        raise ValueError("Unsupported input: Settings search provider missing or duplicated.")
    before = matches[0].group()
    after = re.sub(r' android:enabled="[^"]*"', '', before).replace("<provider ", '<provider android:enabled="false" ', 1)
    manifest = replace_once(manifest, before, after)
    for service in ("com.samsung.android.support.senl.nt.model.service.NotesWordDocumentService",
                    "com.samsung.android.support.senl.nt.model.collector.CollectService"):
        name = f'android:name="{service}"'
        manifest = replace_once(manifest, name, 'android:foregroundServiceType="dataSync" ' + name)
    permission = '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>'
    if permission not in manifest:
        manifest = replace_once(manifest, '<application ', permission + '\n    <application ')
    if bridge:
        bridge_manifest = Path(__file__).parent.parent / "android/native-bridge/src/main/AndroidManifest.xml"
        # Preserve Samsung's existing resource references and namespace spelling.
        xml = bridge_manifest.read_text(encoding="utf-8")
        ET.fromstring(xml)
        additions = xml.split("<application>", 1)[1].split("</application>", 1)[0]
        manifest = replace_once(manifest, "</application>", additions + "</application>")
    version_file = decoded / "apktool.yml"
    version = replace_once(version_file.read_text(encoding="utf-8"), f"versionName: {BASE_VERSION}\n", f"versionName: {BETA_VERSION}\n")
    # Validate every expected boundary before writing either file.
    manifest_file.write_text(manifest, encoding="utf-8")
    version_file.write_text(version, encoding="utf-8")
    for path, text in changes.items():
        path.write_text(text, encoding="utf-8")
    shutil.copytree(shim_source, shim_target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", required=True, type=Path)
    parser.add_argument("--decoded", required=True, type=Path)
    parser.add_argument("--bridge", action="store_true", help="Include shared account hooks and selectable native cloud sync")
    args = parser.parse_args()
    patch(args.decoded, args.original, args.bridge)
