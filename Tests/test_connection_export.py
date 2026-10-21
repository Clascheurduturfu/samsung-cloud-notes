import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import win32crypt
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("export_connection", ROOT / "scripts" / "export_connection.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class ConnectionExportTests(unittest.TestCase):
    def test_encrypted_export_roundtrip_and_protected_code(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict(os.environ, {"LOCALAPPDATA": temp}):
                output = Path(temp) / "Connection.samsungconnection"
                bearer = "Bearer synthetic-test-session-never-a-real-token"
                code = exporter.write_export(bearer, "Fixture", output)
                raw = output.read_text()
                self.assertNotIn(bearer, raw)
                self.assertNotIn(code, raw)
                envelope = json.loads(raw)
                self.assertEqual(envelope["version"], 1)
                key = base64.b64decode(code)
                protected_key = exporter.key_path(output).read_bytes()
                self.assertNotIn(key, protected_key)
                self.assertEqual(win32crypt.CryptUnprotectData(protected_key, None, None, None, 0)[1], key)
                combined = base64.b64decode(envelope["sealed"])
                session = json.loads(AESGCM(key).decrypt(combined[:12], combined[12:], None))
                self.assertEqual(session, {"authorization": bearer, "account": "Fixture"})
                corrupted = bytearray(combined)
                corrupted[-1] ^= 1
                with self.assertRaises(InvalidTag):
                    AESGCM(key).decrypt(bytes(corrupted[:12]), bytes(corrupted[12:]), None)

    def test_rejects_header_injection(self):
        for authorization in ["not-a-bearer", "Bearer token\nInjected: value", "Bearer token\rvalue"]:
            with self.assertRaises(ValueError):
                exporter.write_export(authorization, "Fixture", ROOT / "work" / "should-not-exist")

    def test_connection_codes_do_not_collide_by_filename(self):
        self.assertNotEqual(exporter.key_path(ROOT / "work" / "one" / "Account.samsungconnection"), exporter.key_path(ROOT / "work" / "two" / "Account.samsungconnection"))


if __name__ == "__main__":
    unittest.main()
