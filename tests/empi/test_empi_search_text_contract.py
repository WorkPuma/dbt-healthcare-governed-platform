"""Contract tests for dbt scripts/empi/search_text.py (DEV-4535 parity)."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "empi" / "search_text.py"
SPEC = importlib.util.spec_from_file_location("empi_search_text", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EmpiSearchTextContractTests(unittest.TestCase):
    def test_expected_dim(self):
        self.assertEqual(MODULE.EXPECTED_EMBEDDING_DIM, 768)

    def test_labeled_format(self):
        text = MODULE.create_search_text(
            "Jane",
            "Doe",
            phone="(555) 123-4567",
            email="REDACTED_EMAIL",
            address="123 Main Street Apt 4",
        )
        self.assertEqual(
            text,
            "Patient JANE DOE phone 5551234567 email REDACTED_EMAIL address 123 MAIN ST",
        )

    def test_phone_strips_country_code(self):
        self.assertEqual(MODULE.normalize_phone("+15551234567"), "5551234567")

    def test_assert_dim_accepts_768(self):
        MODULE.assert_embedding_dimension(768)

    def test_assert_dim_rejects_non_768(self):
        with self.assertRaises(ValueError):
            MODULE.assert_embedding_dimension(384)


if __name__ == "__main__":
    unittest.main()
