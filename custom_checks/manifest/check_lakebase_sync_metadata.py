"""
ServingDB Sync Metadata Compliance Check for dbt-bouncer.

Validates that every model under ``models/marts_bi_v3/`` (the ServingDB
boundary) declares the full set of metadata that
``prefect/prefect-jobs/servingdb_sync.py`` requires to register, sync, and
annotate the model in ServingDB Postgres. The sync engine itself silently
skips/downgrades misconfigured models — by the time you notice, your BI
dashboard is stale. This check catches the gaps at PR time.

Required on every marts_bi_v3 model:
  - ``config.meta.servingdb_sync: true``                  — opt-in flag
  - ``config.meta.servingdb_mode: TRIGGERED|SNAPSHOT``    — explicit sync mode
  - ``config.contract.enforced: true``                   — column contract
  - A column with ``constraints: [{type: not_null}]`` AND a ``unique`` test
    (= the surrogate PK ``servingdb_sync.py`` registers as the Postgres PK)

Additionally, when ``servingdb_mode`` is ``SNAPSHOT`` the model MUST also
declare ``config.meta.servingdb_snapshot_reason: <string>`` — every SNAPSHOT
should be a deliberate, documented choice (e.g. "ML batch regeneration",
"upstream needs source_updated_at"), never a silent default.

Exemptions:
  - ``config.meta.servingdb_sync_exempt: true`` — skip every gate.
  - Models that are not synced to ServingDB (e.g. internal-only marts)
    should set ``servingdb_sync: false`` *and* ``servingdb_sync_exempt: true``.

Usage in dbt-bouncer.yml:
    manifest_checks:
      - name: check_servingdb_sync_metadata
        include: ^models/marts_bi_v3/
"""

from typing import TYPE_CHECKING, Literal, Optional
from pydantic import Field
from dbt_bouncer.check_base import BaseCheck

if TYPE_CHECKING:
    import warnings
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=UserWarning)
        from dbt_bouncer.parsers import DbtBouncerModelBase


VALID_MODES = {"TRIGGERED", "SNAPSHOT"}


def _get_meta(model: "DbtBouncerModelBase") -> dict:
    meta: dict = {}
    if hasattr(model, "config") and model.config is not None:
        meta.update(getattr(model.config, "meta", {}) or {})
    if hasattr(model, "meta") and model.meta:
        meta.update(model.meta)
    return meta


def _contract_enforced(model: "DbtBouncerModelBase") -> bool:
    """True if config.contract.enforced is true."""
    if not hasattr(model, "config") or model.config is None:
        return False
    contract = getattr(model.config, "contract", None)
    if contract is None:
        return False
    if isinstance(contract, dict):
        return bool(contract.get("enforced"))
    return bool(getattr(contract, "enforced", False))


def _has_pk_with_constraints_and_tests(model: "DbtBouncerModelBase") -> Optional[str]:
    """
    Return the PK column name if exactly one column has BOTH a not_null
    constraint AND a unique test (the servingdb_sync.py registration contract),
    else None.
    """
    columns = getattr(model, "columns", None) or {}
    if isinstance(columns, dict):
        column_iter = columns.values()
    else:
        column_iter = columns

    for col in column_iter:
        name = getattr(col, "name", None) or (col.get("name") if isinstance(col, dict) else None)
        if not name:
            continue
        constraints = (
            getattr(col, "constraints", None)
            or (col.get("constraints") if isinstance(col, dict) else None)
            or []
        )
        has_not_null_constraint = any(
            (getattr(c, "type", None) or (c.get("type") if isinstance(c, dict) else None)) == "not_null"
            for c in constraints
        )
        tests = (
            getattr(col, "tests", None)
            or (col.get("tests") if isinstance(col, dict) else None)
            or getattr(col, "data_tests", None)
            or (col.get("data_tests") if isinstance(col, dict) else None)
            or []
        )
        has_unique_test = any(
            (t == "unique") or (isinstance(t, dict) and "unique" in t)
            for t in tests
        )
        if has_not_null_constraint and has_unique_test:
            return name
    return None


class CheckServingDBSyncMetadata(BaseCheck):
    """
    Enforce the ServingDB sync metadata contract on marts_bi_v3 models.

    See module docstring for the required fields.
    """

    model: "DbtBouncerModelBase" = Field(default=None)
    name: Literal["check_servingdb_sync_metadata"]

    def execute(self) -> None:
        model = self.model
        meta = _get_meta(model)

        if meta.get("servingdb_sync_exempt") is True:
            return

        model_name = getattr(model, "name", "<unknown>")
        violations: list[str] = []

        if meta.get("servingdb_sync") is not True:
            violations.append(
                "missing `config.meta.servingdb_sync: true` (every marts_bi_v3 model "
                "is a ServingDB boundary by convention — set servingdb_sync_exempt: true "
                "to opt out)"
            )

        mode = (meta.get("servingdb_mode") or "").upper()
        if mode not in VALID_MODES:
            violations.append(
                f"missing or invalid `config.meta.servingdb_mode` (got {meta.get('servingdb_mode')!r}, "
                f"expected one of {sorted(VALID_MODES)})"
            )
        elif mode == "SNAPSHOT" and not (meta.get("servingdb_snapshot_reason") or "").strip():
            violations.append(
                "SNAPSHOT mode requires `config.meta.servingdb_snapshot_reason: <string>` — "
                "every SNAPSHOT must be a deliberate, documented choice (TRIGGERED with CDF "
                "is the default for marts_bi_v3)"
            )

        if not _contract_enforced(model):
            violations.append(
                "missing `config.contract.enforced: true` — marts_bi_v3 is the ServingDB "
                "boundary; contract enforcement catches breaking schema changes before they "
                "force a full ServingDB re-snapshot"
            )

        pk_col = _has_pk_with_constraints_and_tests(model)
        if not pk_col:
            violations.append(
                "no column has BOTH `constraints: [{type: not_null}]` AND a `unique` test — "
                "servingdb_sync.py needs a surrogate PK to register the synced table "
                "(pg_graphql also requires a Postgres PRIMARY KEY)"
            )

        if violations:
            bullet = "\n    - "
            raise AssertionError(
                f"ServingDB sync metadata gaps on `{model_name}`:"
                + bullet
                + bullet.join(violations)
            )
