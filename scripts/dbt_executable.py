"""Resolve the dbt CLI: prefer dbt Fusion (`dbtf`), fall back to dbt-core (`dbt`)."""

from __future__ import annotations

import os
import shutil


def resolve_dbt_cli() -> str:
    override = os.environ.get("DBT_CLI", "").strip()
    if override:
        return override
    if shutil.which("dbtf"):
        return "dbtf"
    if shutil.which("dbt"):
        return "dbt"
    raise RuntimeError(
        "Neither 'dbtf' nor 'dbt' found on PATH. Install dbt Fusion: "
        "https://REDACTED.getdbt.com/... "
        "Or set DBT_CLI to the executable path."
    )
