#!/usr/bin/env python3
"""Rank dbt models by evidence that they are unused.

The audit combines dbt's manifest with Unity Catalog lineage/query history.
It never modifies dbt models or warehouse objects.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

DEFAULT_EXCLUDED_CLIENTS = ("dbt", "Databricks Dbt")
KNOWN_CONSUMER_PATTERN = (
    r"(?i)(tableau|power\s*bi|preset|cube|dashboard|sql editor|excel|"
    r"node|jdbc|odbc|quest)"
)
TERMINAL_STATES = {"SUCCEEDED", "FAILED", "CANCELED", "CLOSED"}
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.$-]+$")


@dataclass(frozen=True)
class ModelEvidence:
    unique_id: str
    name: str
    relation_name: str
    original_file_path: str
    owner: str | None
    servingdb_sync: bool
    dbt_dependents: int
    exposures: int
    external_reads: int
    known_consumer_reads: int
    unknown_consumer_reads: int
    pipeline_reads: int
    distinct_readers: int
    last_external_read: str | None
    observed_days: int
    classification: str
    dead_confidence: int
    reasons: list[str]


def quote_sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def relation_key(value: Any) -> str:
    if value is None or value == "":
        return ""
    if not isinstance(value, str):
        raise TypeError(
            f"relation_name must be a string, got {type(value).__name__}"
        )
    return value.replace("`", "").strip().lower()


def nested_meta(node: dict[str, Any]) -> dict[str, Any]:
    config = node.get("config") or {}
    return {**(node.get("meta") or {}), **(config.get("meta") or {})}


def load_manifest(path: Path) -> tuple[dict[str, dict[str, Any]], int]:
    manifest = json.loads(path.read_text())
    nodes = manifest.get("nodes", {})
    child_map = manifest.get("child_map", {})
    project_name = (manifest.get("metadata") or {}).get("project_name")
    resources = {
        **nodes,
        **manifest.get("sources", {}),
        **manifest.get("semantic_models", {}),
        **manifest.get("metrics", {}),
        **manifest.get("saved_queries", {}),
        **manifest.get("exposures", {}),
    }
    exposures = manifest.get("exposures", {})
    exposure_counts: dict[str, int] = {}
    for exposure in exposures.values():
        for dependency in (exposure.get("depends_on") or {}).get("nodes", []):
            exposure_counts[dependency] = exposure_counts.get(dependency, 0) + 1

    models: dict[str, dict[str, Any]] = {}
    for unique_id, node in nodes.items():
        if node.get("resource_type") != "model" or node.get("config", {}).get("enabled") is False:
            continue
        if project_name and node.get("package_name") != project_name:
            continue
        relation = relation_key(node.get("relation_name"))
        if not relation:
            continue
        dependents = 0
        for child in child_map.get(unique_id, []):
            resource = resources.get(child, {})
            resource_type = resource.get("resource_type")
            if resource_type in {
                "model",
                "snapshot",
                "semantic_model",
                "metric",
                "saved_query",
            }:
                dependents += 1
                continue
            # Singular tests lack test_metadata and are real consumers;
            # generic YAML schema tests (unique/not_null/…) are not.
            if resource_type == "test" and not resource.get("test_metadata"):
                dependents += 1
        tags = set(node.get("tags") or (node.get("config") or {}).get("tags") or [])
        if node.get("time_spine") or "time_spine" in tags:
            dependents += 1
        models[relation] = {
            "unique_id": unique_id,
            "node": node,
            "dbt_dependents": dependents,
            "exposures": exposure_counts.get(unique_id, 0),
        }
    return models, len(exposures)


def build_usage_sql(
    relations: list[str],
    lookback_days: int,
    excluded_clients: list[str],
    excluded_principals: list[str],
    excluded_pipeline_ids: list[str],
) -> str:
    if not 1 <= lookback_days <= 365:
        raise ValueError("lookback days must be between 1 and 365")
    if not relations:
        raise ValueError("manifest contains no enabled model relations")
    for value in relations:
        if not all(SAFE_NAME.fullmatch(part) for part in value.split(".")):
            raise ValueError(f"unsafe relation name in manifest: {value}")

    relation_values = ",\n      ".join(
        f"({quote_sql_string(value)})" for value in relations
    )
    clients = ", ".join(quote_sql_string(value.lower()) for value in excluded_clients)
    principals = ", ".join(quote_sql_string(value.lower()) for value in excluded_principals)
    pipelines = ", ".join(quote_sql_string(value) for value in excluded_pipeline_ids)
    client_filter = (
        f"LOWER(COALESCE(q.client_application, '')) IN ({clients})"
        if clients
        else "FALSE"
    )
    principal_filter = (
        f"LOWER(COALESCE(q.executed_as, q.executed_by, l.created_by, '')) IN ({principals})"
        if principals
        else "FALSE"
    )
    pipeline_filter = (
        f"COALESCE(l.entity_id, '') IN ({pipelines})" if pipelines else "FALSE"
    )

    return f"""
WITH requested_relations AS (
  SELECT relation_name FROM VALUES
      {relation_values}
    AS requested_relations(relation_name)
),
relation_events AS (
  SELECT LOWER(l.source_table_full_name) AS relation_name, l.event_time
  FROM `system`.`access`.`table_lineage` l
  INNER JOIN requested_relations r
    ON LOWER(l.source_table_full_name) = r.relation_name
  WHERE l.event_time >= current_timestamp() - INTERVAL {lookback_days} DAYS
  UNION ALL
  SELECT LOWER(l.target_table_full_name) AS relation_name, l.event_time
  FROM `system`.`access`.`table_lineage` l
  INNER JOIN requested_relations r
    ON LOWER(l.target_table_full_name) = r.relation_name
  WHERE l.event_time >= current_timestamp() - INTERVAL {lookback_days} DAYS
),
coverage AS (
  SELECT
    r.relation_name,
    COALESCE(LEAST(
      {lookback_days},
      DATEDIFF(current_timestamp(), MIN(e.event_time))
    ), 0) AS observed_days
  FROM requested_relations r
  LEFT JOIN relation_events e ON e.relation_name = r.relation_name
  GROUP BY r.relation_name
),
events AS (
  SELECT
    LOWER(l.source_table_full_name) AS relation_name,
    q.statement_id,
    q.start_time,
    q.executed_by,
    q.client_application,
    l.entity_type,
    CASE
      WHEN l.entity_type = 'PIPELINE' OR {pipeline_filter} THEN 'PIPELINE'
      WHEN l.entity_type IN ('DASHBOARD_V3', 'DBSQL_DASHBOARD', 'DBSQL_QUERY')
        THEN 'KNOWN_CONSUMER'
      WHEN q.statement_id IS NULL THEN 'UNKNOWN_CONSUMER'
      WHEN q.execution_status <> 'FINISHED' OR q.statement_type <> 'SELECT' THEN 'NON_READ'
      WHEN {client_filter} OR {principal_filter} THEN 'PRODUCER'
      WHEN COALESCE(q.client_application, '') RLIKE {quote_sql_string(KNOWN_CONSUMER_PATTERN)}
        THEN 'KNOWN_CONSUMER'
      ELSE 'UNKNOWN_CONSUMER'
    END AS usage_class
  FROM `system`.`access`.`table_lineage` l
  LEFT JOIN `system`.`query`.`history` q ON q.statement_id = l.statement_id
  INNER JOIN requested_relations r
    ON LOWER(l.source_table_full_name) = r.relation_name
  WHERE l.event_time >= current_timestamp() - INTERVAL {lookback_days} DAYS
)
SELECT
  r.relation_name,
  COUNT_IF(e.usage_class IN ('KNOWN_CONSUMER', 'UNKNOWN_CONSUMER')) AS external_reads,
  COUNT_IF(e.usage_class = 'KNOWN_CONSUMER') AS known_consumer_reads,
  COUNT_IF(e.usage_class = 'UNKNOWN_CONSUMER') AS unknown_consumer_reads,
  COUNT_IF(e.usage_class = 'PIPELINE') AS pipeline_reads,
  COUNT(DISTINCT CASE WHEN e.usage_class IN ('KNOWN_CONSUMER', 'UNKNOWN_CONSUMER')
    THEN e.executed_by END) AS distinct_readers,
  MAX(CASE WHEN e.usage_class IN ('KNOWN_CONSUMER', 'UNKNOWN_CONSUMER')
    THEN e.start_time END) AS last_external_read,
  MAX(c.observed_days) AS observed_days
FROM requested_relations r
INNER JOIN coverage c ON c.relation_name = r.relation_name
LEFT JOIN events e ON e.relation_name = r.relation_name
GROUP BY r.relation_name
ORDER BY r.relation_name
""".strip()


def databricks_api(
    method: str, path: str, profile: str | None, body: dict[str, Any] | None = None
) -> dict[str, Any]:
    command = ["databricks", "api", method, path, "--output", "json"]
    if profile:
        command.extend(["--profile", profile])
    temp_path: Path | None = None
    try:
        if body is not None:
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
                json.dump(body, handle)
                temp_path = Path(handle.name)
            command.extend(["--json", f"@{temp_path}"])
        completed = subprocess.run(
            command, check=True, capture_output=True, text=True
        )
        return json.loads(completed.stdout)
    except FileNotFoundError as exc:
        raise RuntimeError("Databricks CLI is required for live mode") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or exc.stdout.strip()
        raise RuntimeError(f"Databricks API request failed: {detail}") from exc
    finally:
        if temp_path:
            temp_path.unlink(missing_ok=True)


def rows_from_response(
    response: dict[str, Any], profile: str | None
) -> list[dict[str, Any]]:
    manifest = response.get("manifest") or {}
    columns = [
        column["name"]
        for column in (manifest.get("schema") or {}).get("columns", [])
    ]
    if not columns:
        raise RuntimeError("statement response did not include a result schema")
    statement_id = response.get("statement_id")
    if not statement_id:
        raise RuntimeError("statement response did not include a statement_id")
    total_chunks = int(manifest.get("total_chunk_count") or 1)
    rows: list[dict[str, Any]] = []
    result = response.get("result") or {}
    seen_chunks: set[int] = set()
    while True:
        chunk_index = int(result.get("chunk_index") or 0)
        if chunk_index in seen_chunks:
            raise RuntimeError(
                f"statement {statement_id} returned duplicate chunk {chunk_index}"
            )
        seen_chunks.add(chunk_index)
        rows.extend(dict(zip(columns, values)) for values in result.get("data_array", []))
        next_index = result.get("next_chunk_index")
        if next_index is None and chunk_index + 1 < total_chunks:
            next_index = chunk_index + 1
        if next_index is None:
            break
        result = databricks_api(
            "get",
            f"/api/2.0/sql/statements/{statement_id}/result/chunks/{next_index}",
            profile,
        )
    if len(seen_chunks) < total_chunks:
        raise RuntimeError(
            f"statement {statement_id} returned {len(seen_chunks)} of "
            f"{total_chunks} result chunks"
        )
    return rows


def execute_usage_sql(
    sql: str,
    warehouse_id: str,
    profile: str | None,
    poll_seconds: float = 2.0,
    max_wait_seconds: float = 900.0,
) -> list[dict[str, Any]]:
    response = databricks_api(
        "post",
        "/api/2.0/sql/statements",
        profile,
        {
            "statement": sql,
            "warehouse_id": warehouse_id,
            "wait_timeout": "30s",
            "disposition": "INLINE",
            "format": "JSON_ARRAY",
        },
    )
    statement_id = response.get("statement_id")
    if not statement_id:
        raise RuntimeError("Databricks did not return a statement_id")
    deadline = time.monotonic() + max_wait_seconds
    while response.get("status", {}).get("state") not in TERMINAL_STATES:
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"statement {statement_id} did not finish within {max_wait_seconds:.0f}s"
            )
        time.sleep(poll_seconds)
        response = databricks_api(
            "get", f"/api/2.0/sql/statements/{statement_id}", profile
        )
    state = response.get("status", {}).get("state")
    if state != "SUCCEEDED":
        error = response.get("status", {}).get("error", {})
        raise RuntimeError(f"statement {state}: {error.get('message', 'unknown error')}")
    return rows_from_response(response, profile)


def load_usage_rows(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text())
    if not isinstance(payload, list):
        raise ValueError(f"{path} must contain a JSON array of usage row objects")
    rows: list[dict[str, Any]] = []
    for index, row in enumerate(payload):
        if not isinstance(row, dict):
            raise ValueError(f"{path} row {index} must be an object")
        if "relation_name" not in row:
            raise ValueError(f"{path} row {index} missing relation_name")
        if not isinstance(row["relation_name"], str):
            raise TypeError(
                f"{path} row {index} relation_name must be a string, "
                f"got {type(row['relation_name']).__name__}"
            )
        rows.append(row)
    return rows


def integer(value: Any) -> int:
    return int(value or 0)


def score_model(
    relation: str,
    model: dict[str, Any],
    usage: dict[str, Any],
    lookback_days: int,
) -> ModelEvidence:
    node = model["node"]
    meta = nested_meta(node)
    external_reads = integer(usage.get("external_reads"))
    known_reads = integer(usage.get("known_consumer_reads"))
    unknown_reads = integer(usage.get("unknown_consumer_reads"))
    pipeline_reads = integer(usage.get("pipeline_reads"))
    observed_days = integer(usage.get("observed_days"))
    dependents = integer(model["dbt_dependents"])
    exposures = integer(model["exposures"])
    servingdb_sync = bool(meta.get("servingdb_sync"))
    reasons: list[str] = []

    if external_reads:
        classification = "LIVE_OBSERVED"
        confidence = 0
        reasons.append(f"{external_reads} external reads in {observed_days} observed days")
    elif dependents or exposures:
        classification = "LIVE_DECLARED"
        confidence = 0
        if dependents:
            reasons.append(f"{dependents} declared dbt/semantic dependents")
        if exposures:
            reasons.append(f"{exposures} declared dbt exposures")
    elif servingdb_sync:
        classification = "SERVINGDB_ONLY_UNVERIFIED"
        confidence = 25
        reasons.append("published to ServingDB but Postgres reads are not observable here")
    else:
        classification = "CANDIDATE_DEAD"
        confidence = 35
        reasons.append("no dbt dependents, exposures, or external reads")

    if classification in {"CANDIDATE_DEAD", "SERVINGDB_ONLY_UNVERIFIED"}:
        coverage = min(observed_days, lookback_days) / lookback_days
        confidence += round((35 if servingdb_sync else 50) * coverage)
        reasons.append(f"query/lineage coverage is {observed_days}/{lookback_days} days")
        if pipeline_reads:
            reasons.append(f"{pipeline_reads} pipeline reads excluded as producer activity")
        confidence = max(0, min(99, confidence))
    elif unknown_reads:
        reasons.append(f"{unknown_reads} reads have an unrecognized consumer client")

    owner = meta.get("owner")
    if isinstance(owner, dict):
        owner = owner.get("email") or owner.get("name")
    return ModelEvidence(
        unique_id=model["unique_id"],
        name=node.get("name", model["unique_id"]),
        relation_name=relation,
        original_file_path=node.get("original_file_path", ""),
        owner=str(owner) if owner else None,
        servingdb_sync=servingdb_sync,
        dbt_dependents=dependents,
        exposures=exposures,
        external_reads=external_reads,
        known_consumer_reads=known_reads,
        unknown_consumer_reads=unknown_reads,
        pipeline_reads=pipeline_reads,
        distinct_readers=integer(usage.get("distinct_readers")),
        last_external_read=usage.get("last_external_read"),
        observed_days=observed_days,
        classification=classification,
        dead_confidence=confidence,
        reasons=reasons,
    )


def score_models(
    models: dict[str, dict[str, Any]],
    usage_rows: list[dict[str, Any]],
    lookback_days: int,
) -> list[ModelEvidence]:
    usage: dict[str, dict[str, Any]] = {}
    for row in usage_rows:
        key = relation_key(row.get("relation_name"))
        if not key:
            raise ValueError("usage row relation_name must be a non-empty string")
        usage[key] = row
    results = [
        score_model(relation, model, usage.get(relation, {}), lookback_days)
        for relation, model in models.items()
    ]
    return sorted(
        results,
        key=lambda item: (
            item.classification not in {"CANDIDATE_DEAD", "SERVINGDB_ONLY_UNVERIFIED"},
            -item.dead_confidence,
            item.relation_name,
        ),
    )


def write_csv(path: Path, results: list[ModelEvidence]) -> None:
    rows = [asdict(item) for item in results]
    if not rows:
        return
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        for row in rows:
            row["reasons"] = "; ".join(row["reasons"])
            writer.writerow(row)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rank potentially unused dbt models using Databricks runtime evidence."
    )
    parser.add_argument("--manifest", type=Path, default=Path("target/manifest.json"))
    parser.add_argument("--warehouse-id", help="Required unless --usage-json is supplied")
    parser.add_argument("--profile", help="Databricks CLI profile")
    parser.add_argument("--usage-json", type=Path, help="Use previously exported usage rows")
    parser.add_argument("--lookback-days", type=int, default=90)
    parser.add_argument(
        "--exclude-client",
        action="append",
        default=[],
        help="Producer client application to exclude; repeatable",
    )
    parser.add_argument(
        "--exclude-principal",
        action="append",
        default=[],
        help="Producer service principal/user to exclude; repeatable",
    )
    parser.add_argument(
        "--exclude-pipeline-id",
        action="append",
        default=[],
        help="Known sync pipeline ID to exclude; repeatable",
    )
    parser.add_argument("--json", type=Path, default=Path("dead-model-audit.json"))
    parser.add_argument("--csv", type=Path, default=Path("dead-model-audit.csv"))
    parser.add_argument("--sql-out", type=Path, help="Write generated SQL for review")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.manifest.exists():
        print(
            f"manifest not found: {args.manifest}; "
            "run `dbt parse` first (org wrapper: `dbt parse` under your-secret-manager)",
            file=sys.stderr,
        )
        return 2
    try:
        models, exposure_total = load_manifest(args.manifest)
        excluded_clients = [*DEFAULT_EXCLUDED_CLIENTS, *args.exclude_client]
        sql = build_usage_sql(
            sorted(models),
            args.lookback_days,
            excluded_clients,
            args.exclude_principal,
            args.exclude_pipeline_id,
        )
        if args.sql_out:
            args.sql_out.write_text(sql + "\n")
        if args.usage_json:
            usage_rows = load_usage_rows(args.usage_json)
        else:
            if not args.warehouse_id:
                print("--warehouse-id is required for live mode", file=sys.stderr)
                return 2
            usage_rows = execute_usage_sql(sql, args.warehouse_id, args.profile)
        results = score_models(models, usage_rows, args.lookback_days)
        payload = {
            "generated_at_epoch": int(time.time()),
            "lookback_days": args.lookback_days,
            "models_scored": len(results),
            "manifest_exposures": exposure_total,
            "excluded_clients": excluded_clients,
            "excluded_principals": args.exclude_principal,
            "results": [asdict(item) for item in results],
        }
        args.json.write_text(json.dumps(payload, indent=2) + "\n")
        write_csv(args.csv, results)
    except (OSError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
        print(f"dead-model audit failed: {exc}", file=sys.stderr)
        return 1

    candidates = sum(item.dead_confidence > 0 for item in results)
    print(f"Scored {len(results)} models; {candidates} require dead-code review.")
    print(f"Wrote {args.json} and {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
