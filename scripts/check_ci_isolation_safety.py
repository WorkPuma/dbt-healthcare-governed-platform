#!/usr/bin/env python3
"""Guard against config that bypasses CI/PR schema isolation.

Background
----------
PR validation runs ``dbt build --select state:modified+ --defer`` in dbt Cloud
with ``schema_override=dbt_cloud_pr_<job>_<pr>``. The ``generate_schema_name``
macro detects the ``dbt_cloud_pr_`` prefix and routes every selected model into
that throwaway PR schema, so an unmerged PR never writes to prod.

Two config patterns silently escape that envelope and leak toward prod
(this is what caused the snapshot tables to land in
``databricks_prod.snapshots`` and the MDM ``CREATE SCHEMA`` permission failure):

1. A snapshot using ``target_schema=``. ``target_schema`` is a hard pin that
   bypasses ``generate_schema_name`` entirely, so ``schema_override`` is ignored
   and the snapshot is written straight into the real schema. Snapshots MUST use
   ``schema=`` so they route through the macro.

2. A model/snapshot hard-pinning ``database=``/``+database:`` to a literal
   catalog (e.g. ``mdm``). ``schema_override`` overrides the schema but NOT the
   catalog, so in CI dbt tries to ``CREATE`` the PR schema inside that catalog,
   where the CI service principal has no grant. A hard catalog pin must be
   wrapped in a CI-aware Jinja conditional, e.g.::

      +database: "{{ target.database if (target.schema | lower).startswith('dbt_cloud_pr') else 'mdm' }}"

Exit codes: 0 = clean, 1 = one or more isolation hazards found.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# The connection's default catalog. CI builds into this catalog (the CI
# service principal can create the dbt_cloud_pr_* schema here), so pinning a
# model to it is harmless — only pins to a NON-default catalog (e.g. `mdm`)
# break isolation, because schema_override can't redirect the catalog.
DEFAULT_CATALOG = "databricks_prod"

# A database value is CI-safe if it is dynamic: a Jinja expression ({{ ... }})
# or derived from the runtime target (target.database). A bare quoted literal
# is a hard pin UNLESS it is the default catalog.
_SAFE_DB = ("{{", "target.")

# config(database='literal') / config(database="literal") in a .sql config block
_SQL_DB = re.compile(r"""database\s*=\s*(['"])(?P<val>.*?)\1""", re.IGNORECASE | re.DOTALL)
# {% snapshot %} blocks set target_schema=... — the hazard we forbid outright
_SNAP_TARGET_SCHEMA = re.compile(r"target_schema\s*=", re.IGNORECASE)
_SNAP_SCHEMA = re.compile(r"\bschema\s*=", re.IGNORECASE)
# dbt_project.yml +database: value (rest of line after the key)
_YML_DB = re.compile(r"^\s*\+database\s*:\s*(?P<val>.+?)\s*$")


def _db_value_is_hardpin(raw: str) -> bool:
    """True when a database value is a static literal (not Jinja / target-derived)."""
    val = raw.strip().strip("'\"").strip()
    if not val:
        return False
    if any(token in raw for token in _SAFE_DB):
        return False
    return val != DEFAULT_CATALOG


def check_snapshots() -> list[str]:
    violations: list[str] = []
    snap_dir = REPO / "snapshots"
    for sql in sorted(snap_dir.rglob("*.sql")):
        text = sql.read_text(encoding="utf-8")
        rel = sql.relative_to(REPO)
        if _SNAP_TARGET_SCHEMA.search(text):
            violations.append(
                f"{rel}: uses `target_schema=` — this bypasses generate_schema_name "
                f"and schema_override, so CI writes it straight to prod. Use `schema='snapshots'` instead."
            )
        elif not _SNAP_SCHEMA.search(text):
            violations.append(
                f"{rel}: snapshot sets neither `schema=` nor `target_schema=`. "
                f"Set `schema='snapshots'` so it lands in the snapshots schema (and routes through CI isolation)."
            )
        for m in _SQL_DB.finditer(text):
            if _db_value_is_hardpin(m.group("val")):
                violations.append(
                    f"{rel}: hard-pins `database='{m.group('val')}'` — `schema_override` cannot "
                    f"redirect the catalog, so CI fails to create the PR schema there. "
                    f"Wrap it in a `dbt_cloud_pr`-aware Jinja conditional."
                )
    return violations


def check_models() -> list[str]:
    violations: list[str] = []
    models_dir = REPO / "models"
    for sql in sorted(models_dir.rglob("*.sql")):
        text = sql.read_text(encoding="utf-8")
        if "config(" not in text:
            continue
        rel = sql.relative_to(REPO)
        for m in _SQL_DB.finditer(text):
            if _db_value_is_hardpin(m.group("val")):
                violations.append(
                    f"{rel}: hard-pins `database='{m.group('val')}'` in config() — "
                    f"wrap it in a `dbt_cloud_pr`-aware Jinja conditional so CI isolation can redirect it."
                )
    return violations


def check_project_yml() -> list[str]:
    violations: list[str] = []
    proj = REPO / "dbt_project.yml"
    if not proj.exists():
        return violations
    for i, line in enumerate(proj.read_text(encoding="utf-8").splitlines(), start=1):
        m = _YML_DB.match(line)
        if m and _db_value_is_hardpin(m.group("val")):
            violations.append(
                f"dbt_project.yml:{i}: `+database: {m.group('val').strip()}` is a hard catalog pin. "
                f"Wrap it in a `dbt_cloud_pr`-aware Jinja conditional so CI builds into the default catalog."
            )
    return violations


def main() -> int:
    violations = check_snapshots() + check_models() + check_project_yml()
    if violations:
        print("CI isolation safety check FAILED — these configs bypass PR schema isolation:\n")
        for v in violations:
            print(f"  - {v}")
        print(
            "\nWhy this matters: PR validation builds into dbt_cloud_pr_* schemas via "
            "schema_override so unmerged PRs never touch prod. The configs above escape that.\n"
        )
        return 1
    print("CI isolation safety check PASSED — no schema/catalog hard-pins bypass PR isolation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
