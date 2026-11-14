"""Fail-closed boundaries: unsupported inputs must not leave a partial patch."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch as mock
import patch as profile
from hooks import method, read_only_folder_phase


class ProfileGuards(unittest.TestCase):
    def test_folder_download_patch_skips_upload_without_clearing_pending_edits(self):
        upload = '    const-string v0, "Folder (upSync)"\n    invoke-virtual {v0}, Lfixture;->uploadAndClearDirtyState()V\n    :cond_1f\n    return-void\n'
        result = read_only_folder_phase(upload)
        self.assertIn('->isNativeReadOnly()Z', result)
        self.assertIn('    if-nez v0, :cond_1f\n', result)
        self.assertIn(upload, result)
        for unsupported in ("", upload + upload):
            with self.assertRaisesRegex(ValueError, "upload phase differs"):
                read_only_folder_phase(unsupported)

    def test_wrong_apk_is_rejected_without_mutating_decode(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            original = root / "original.apk"
            original.write_bytes(b"unsupported owner APK")
            decoded = root / "decoded"
            decoded.mkdir()
            manifest = decoded / "AndroidManifest.xml"
            manifest.write_text("unchanged")
            with self.assertRaisesRegex(ValueError, "Unsupported APK"):
                profile.patch(decoded, original)
            self.assertEqual(manifest.read_text(), "unchanged")
            self.assertEqual(sorted(p.name for p in decoded.iterdir()), ["AndroidManifest.xml"])

    def test_existing_extra_dex_is_rejected_before_any_write(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            original = root / "original.apk"
            original.write_bytes(b"fixture")
            decoded = root / "decoded"
            (decoded / "smali_classes13").mkdir(parents=True)
            with mock.object(profile, "APK_SHA256", hashlib.sha256(b"fixture").hexdigest()):
                with self.assertRaisesRegex(ValueError, "classes13 already exists"):
                    profile.patch(decoded, original)
            self.assertEqual(list((decoded / "smali_classes13").iterdir()), [])

    def test_missing_or_duplicate_native_callback_cannot_be_rewritten(self):
        signature = "public callback(Ljava/lang/Object;)V"
        valid = ".method " + signature + "\n    .locals 0\n    return-void\n.end method\n"
        for source in ("", valid + valid):
            with self.subTest(source=source):
                with self.assertRaisesRegex(ValueError, "expected one method"):
                    method(source, signature, "    .locals 0\n    return-void")

    def test_missing_manifest_boundary_is_atomic(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            original = root / "original.apk"
            original.write_bytes(b"fixture")
            decoded = root / "decoded"
            decoded.mkdir()
            text = '<manifest><application><uses-library android:name="com.samsung.device" android:required="true"/></application></manifest>'
            manifest = decoded / "AndroidManifest.xml"
            manifest.write_text(text)
            with mock.object(profile, "APK_SHA256", hashlib.sha256(b"fixture").hexdigest()), mock.object(profile, "compatibility_hooks", return_value={}):
                with self.assertRaisesRegex(ValueError, "Unsupported input"):
                    profile.patch(decoded, original)
            self.assertEqual(manifest.read_text(), text)
            self.assertFalse((decoded / "smali_classes13").exists())


if __name__ == "__main__":
    unittest.main()
