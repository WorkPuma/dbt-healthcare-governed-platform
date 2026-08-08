"""
ServingDB Semantic Description Coverage Check for dbt-bouncer.

The ServingDB semantic chain (YAML descriptions -> manifest.json -> Prefect
servingdb-sync -> COMMENT ON VIEW/COLUMN -> pg_graphql -> BIPlatform BFF) only
carries what the YAML declares. A model that syncs to ServingDB without a
description, or with undocumented columns, lands in Postgres semantically
blank — the BFF's introspection and AI spec grounding return nulls and
nobody notices until a dashboard misbehaves.

This check enforces, for every model in scope (marts_bi_v3 by convention,
plus anything with ``config.meta.servingdb_sync: true``):
  - a non-empty model ``description``
  - at least one documented column
  - a non-empty ``description`` on EVERY declared column

Exemptions:
  - ``config.meta.servingdb_sync_exempt: true`` — same opt-out as
    check_servingdb_sync_metadata.

Usage in dbt-bouncer.yml:
    manifest_checks:
      - name: check_servingdb_sync_descriptions
        include: ^models/marts_bi_v3/
"""

from typing import TYPE_CHECKING, Literal
from pydantic import Field
from dbt_bouncer.check_base import BaseCheck

if TYPE_CHECKING:
    import warnings
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=UserWarning)
        from dbt_bouncer.parsers import DbtBouncerModelBase


def _get_meta(model: "DbtBouncerModelBase") -> dict:
    meta: dict = {}
    if hasattr(model, "config") and model.config is not None:
        meta.update(getattr(model.config, "meta", {}) or {})
    if hasattr(model, "meta") and model.meta:
        meta.update(model.meta)
    return meta


class CheckServingDBSyncDescriptions(BaseCheck):
    """
    Enforce 100% semantic description coverage on ServingDB-synced models.

    See module docstring for the rationale and required fields.
    """

    model: "DbtBouncerModelBase" = Field(default=None)
    name: Literal["check_servingdb_sync_descriptions"]

    def execute(self) -> None:
        model = self.model
        meta = _get_meta(model)

        if meta.get("servingdb_sync_exempt") is True:
            return

        model_name = getattr(model, "name", "<unknown>")
        violations: list[str] = []

        description = (getattr(model, "description", "") or "").strip()
        if not description:
            violations.append(
                "missing model `description` — the ServingDB table-level "
                "@graphql comment falls back to a generic placeholder"
            )

        columns = getattr(model, "columns", None) or {}
        column_iter = columns.values() if isinstance(columns, dict) else columns

        documented = 0
        undocumented: list[str] = []
        for col in column_iter:
            col_name = getattr(col, "name", None) or (
                col.get("name") if isinstance(col, dict) else None
            )
            if not col_name:
                continue
            col_desc = (
                getattr(col, "description", None)
                or (col.get("description") if isinstance(col, dict) else None)
                or ""
            ).strip()
            if col_desc:
                documented += 1
            else:
                undocumented.append(col_name)

        if documented == 0:
            violations.append(
                "no documented columns in YAML — zero COMMENT ON COLUMN "
                "statements will reach ServingDB; pg_graphql field descriptions "
                "will all be null"
            )
        elif undocumented:
            shown = ", ".join(undocumented[:10])
            more = f" (+{len(undocumented) - 10} more)" if len(undocumented) > 10 else ""
            violations.append(
                f"{len(undocumented)} column(s) without a description: "
                f"{shown}{more} — these land in ServingDB semantically blank"
            )

        if violations:
            bullet = "\n    - "
            raise AssertionError(
                f"ServingDB semantic description gaps on `{model_name}`:"
                + bullet
                + bullet.join(violations)
            )
