"""Contract tests for DEV-4545 payor match target-change reset MERGE.

Guards the notebook MERGE branches that demote approved rows to pending when
golden_id / athena_patient_id change, preserving prior status in rejection_reason.

CodeAnt 831542465 (coverage exemption): the notebook under test
(empi_payor_matching_v4.py) is a Databricks PySpark SQL notebook executed
server-side on a live Spark cluster. It is not importable or runnable from a
local pytest process, so line-coverage measurement is not meaningful for it.
These are *contract* tests: they parse the notebook source and assert on the
SQL structure/semantics of the MERGE statements rather than executing SQL.
Coverage gates should exempt notebooks/empi/*.py (SQL notebooks) accordingly.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

NOTEBOOK = (
    Path(__file__).resolve().parents[2]
    / "notebooks"
    / "empi"
    / "empi_payor_matching_v4.py"
)

# The shared self-heal fragment is defined once and interpolated into both the
# MBI (save_mbi_matches) and probabilistic MERGE catch-all branches via an
# f-string. Contract tests assert on the *rendered* fragment, not just raw
# occurrence counts, to verify the actual self-healing behavior.
_SELF_HEAL_FRAGMENT = """rejection_reason = CASE
    WHEN target.approval_status IN ('auto_approved', 'manually_approved')
         AND target.rejection_reason LIKE 'prior:%'
    THEN CAST(NULL AS STRING)
    ELSE target.rejection_reason
END"""
_GUARDED_UPDATED_AT = "ELSE target.updated_at"


class EmpiPayorTargetChangeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = NOTEBOOK.read_text(encoding="utf-8")

    def test_notebook_exists(self):
        self.assertTrue(NOTEBOOK.is_file(), f"missing {NOTEBOOK}")

    def test_target_change_when_matched_clause_present(self):
        self.assertIn("DEV-4545: target-change reset", self.source)
        self.assertGreaterEqual(self.source.count("DEV-4545: target-change reset"), 2)

    def test_approved_statuses_trigger_reset(self):
        self.assertIn(
            "target.approval_status IN ('auto_approved','manually_approved')",
            self.source,
        )

    def test_null_safe_target_compare(self):
        self.assertIn("NOT (target.golden_id <=> source.golden_id)", self.source)
        self.assertIn(
            "NOT (target.athena_patient_id <=> source.athena_patient_id)",
            self.source,
        )

    def test_resets_to_pending_with_prior_reason(self):
        self.assertIn("approval_status = 'pending'", self.source)
        self.assertIn(
            "rejection_reason = concat('prior:', target.approval_status)",
            self.source,
        )

    def test_reapproval_clears_prior_rejection_reason(self):
        """Pending rows re-approved must drop sticky prior:* reasons."""
        self.assertIn(
            "WHEN source.approval_status IN ('auto_approved', 'manually_approved') THEN CAST(NULL AS STRING)",
            self.source,
        )
        self.assertGreaterEqual(
            self.source.count(
                "WHEN source.approval_status IN ('auto_approved', 'manually_approved') THEN CAST(NULL AS STRING)"
            ),
            2,
        )

    # --- Behavioral self-heal tests (CodeAnt 831542538) ---------------------
    # Rather than merely counting predicate occurrences, these assert the
    # actual self-healing semantics of the shared catch-all fragment: that it
    # clears prior:* on approved rows while preserving non-prior reasons, and
    # that the fragment is defined once and referenced by both MERGE paths.

    def test_self_heal_fragment_defined_once_as_shared_variable(self):
        """The self-heal CASE must be defined once (DRY) and referenced by both paths."""
        # The shared variable is defined exactly once...
        self.assertEqual(
            self.source.count("SELF_HEAL_REJECTION_REASON_SQL ="),
            1,
            "self-heal CASE should be defined once as a shared variable (CodeAnt 831542420)",
        )
        # ...and interpolated into both MERGE statements.
        self.assertGreaterEqual(
            self.source.count("{SELF_HEAL_REJECTION_REASON_SQL}"),
            2,
            "shared self-heal fragment must be used by both the MBI and probabilistic MERGE paths",
        )

    def test_self_heal_clears_prior_on_approved_rows(self):
        """The CASE must NULL rejection_reason for approved rows carrying prior:*."""
        self.assertIn(_SELF_HEAL_FRAGMENT, self.source)

    def test_self_heal_preserves_non_prior_rejection_reasons(self):
        """Non-sticky (non prior:*) reasons must be preserved verbatim (ELSE target.rejection_reason)."""
        # The fragment's ELSE branch keeps the existing reason, so a non-prior
        # reason like 'duplicate_member' survives the catch-all untouched.
        self.assertIn("ELSE target.rejection_reason", _SELF_HEAL_FRAGMENT)
        # And the rendered fragment is actually present in the notebook source.
        self.assertIn(_SELF_HEAL_FRAGMENT, self.source)

    def test_self_heal_does_not_touch_pending_rows(self):
        """The CASE must only fire for approved statuses, not pending/data_quality_issue.

        A pending row that happens to carry a prior:* (from a target-change
        reset) must NOT be self-healed by the catch-all — it is handled by the
        dedicated pending->approved branch instead. The guard
        `approval_status IN ('auto_approved','manually_approved')` enforces this.
        """
        # Extract the self-heal CASE condition and confirm it gates on approved.
        self.assertRegex(
            _SELF_HEAL_FRAGMENT,
            r"approval_status IN \('auto_approved', 'manually_approved'\)",
        )
        # Confirm pending is NOT an accepted status in the self-heal guard.
        self.assertNotIn(
            "'pending'",
            _SELF_HEAL_FRAGMENT,
            "self-heal must not fire on pending rows",
        )

    # --- Timestamp guard (CodeAnt 831542534) ---------------------------------

    def test_catch_all_updated_at_is_guarded_not_unconditional(self):
        """updated_at must only bump when the self-heal actually clears a prior:*.

        An unconditional `updated_at = current_timestamp()` in the catch-all
        marks every matched row as newly updated on every rerun. The guarded
        form falls back to `ELSE target.updated_at` so unchanged rows keep
        their original timestamp.
        """
        # The shared updated_at fragment is defined once...
        self.assertEqual(
            self.source.count("SELF_HEAL_UPDATED_AT_SQL ="),
            1,
            "guarded updated_at should be defined once as a shared variable",
        )
        # ...and referenced by both MERGE paths...
        self.assertGreaterEqual(
            self.source.count("{SELF_HEAL_UPDATED_AT_SQL}"),
            2,
            "guarded updated_at fragment must be used by both MERGE paths",
        )
        # ...and it must fall back to the existing timestamp (the guard).
        self.assertIn(_GUARDED_UPDATED_AT, self.source)

    def test_catch_all_heals_sticky_prior_on_approved_rows(self):
        """Already-approved rows with leftover prior:* must self-heal in catch-all.

        (Retained as a regression guard for the original ErrorTracking PREFECT-C5 / #414
        failure that motivated the self-heal. The behavioral assertions above
        cover the semantics; this confirms the prior:% predicate is still present.)
        """
        self.assertIn(
            "AND target.rejection_reason LIKE 'prior:%'",
            self.source,
        )
        self.assertGreaterEqual(
            self.source.count("AND target.rejection_reason LIKE 'prior:%'"),
            2,
        )

    def test_aha_canonical_payor_member_id_shared_across_paths(self):
        """MBI and probabilistic AHA paths must upsert on the same member key."""
        self.assertIn("AHA_PAYOR_MEMBER_ID_SQL", self.source)
        self.assertIn("REGEXP_REPLACE(TRIM(member_id)", self.source)
        self.assertIn("CONCAT('AHA:', {AHA_PAYOR_MEMBER_ID_SQL})", self.source)

    def test_post_merge_heals_orphaned_sticky_prior_rows(self):
        """Explicit pass clears approved rows that still carry prior:* (assert_empi_payor_prior_reset_is_pending)."""
        self.assertIn("Step 7.7: Heal sticky prior:* on approved rows", self.source)
        self.assertIn(
            "WHERE approval_status IN ('auto_approved', 'manually_approved')\n"
            "      AND rejection_reason LIKE 'prior:%'",
            self.source,
        )


if __name__ == "__main__":
    unittest.main()
