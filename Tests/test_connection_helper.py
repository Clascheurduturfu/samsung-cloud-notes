from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import connection_helper as helper


class ConnectionHelperTests(unittest.TestCase):
    def test_cancelling_during_validation_does_not_export(self):
        cancelled = threading.Event()
        with patch.object(helper, "collect_session", return_value="Bearer synthetic-fixture"), \
             patch.object(helper, "validate_session", side_effect=lambda _: cancelled.set()), \
             patch.object(helper, "write_export") as write:
            result = helper.create_connection(Path("unused"), "Fixture", cancelled, lambda _: None)
            self.assertIsNone(result)
            write.assert_not_called()

    def test_rejected_session_does_not_export(self):
        with patch.object(helper, "collect_session", return_value="Bearer synthetic-fixture"), \
             patch.object(helper, "validate_session", side_effect=RuntimeError("Rejected")), \
             patch.object(helper, "write_export") as write:
            with self.assertRaisesRegex(RuntimeError, "Rejected"):
                helper.create_connection(Path("unused"), "Fixture", threading.Event(), lambda _: None)
            write.assert_not_called()

    def test_cancelling_before_validation_skips_network(self):
        cancelled = threading.Event(); cancelled.set()
        with patch.object(helper, "collect_session", return_value="Bearer synthetic-fixture"), \
             patch.object(helper, "validate_session") as validate, \
             patch.object(helper, "write_export") as write:
            self.assertIsNone(helper.create_connection(Path("unused"), "Fixture", cancelled, lambda _: None))
            validate.assert_not_called(); write.assert_not_called()


if __name__ == "__main__":
    unittest.main()
