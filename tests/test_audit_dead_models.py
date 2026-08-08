import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "scripts" / "audit_dead_models.py"
SPEC = importlib.util.spec_from_file_location("audit_dead_models", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DeadModelAuditTests(unittest.TestCase):
    def manifest(self, path: Path) -> None:
        path.write_text(
            json.dumps(
                {
                    "nodes": {
                        "model.proj.dead": {
                            "resource_type": "model",
                            "name": "dead",
                            "relation_name": "`cat`.`analytics`.`dead`",
                            "original_file_path": "models/dead.sql",
                            "config": {"enabled": True, "meta": {}},
                        },
                        "model.proj.synced": {
                            "resource_type": "model",
                            "name": "synced",
                            "relation_name": "`cat`.`analytics`.`synced`",
                            "original_file_path": "models/synced.sql",
                            "config": {
                                "enabled": True,
                                "meta": {"servingdb_sync": True},
                            },
                        },
                        "model.proj.parent": {
                            "resource_type": "model",
                            "name": "parent",
                            "relation_name": "`cat`.`analytics`.`parent`",
                            "original_file_path": "models/parent.sql",
                            "config": {"enabled": True},
                        },
                        "model.proj.child": {
                            "resource_type": "model",
                            "name": "child",
                            "relation_name": "`cat`.`analytics`.`child`",
                            "original_file_path": "models/child.sql",
                            "config": {"enabled": True},
                        },
                        "model.proj.tested_only": {
                            "resource_type": "model",
                            "name": "tested_only",
                            "relation_name": "`cat`.`analytics`.`tested_only`",
                            "original_file_path": "models/tested_only.sql",
                            "config": {"enabled": True},
                        },
                        "test.proj.tested_only_singular": {
                            "resource_type": "test",
                            "name": "tested_only_singular",
                            "original_file_path": "tests/test_tested_only.sql",
                            "depends_on": {"nodes": ["model.proj.tested_only"]},
                        },
                        "test.proj.nested_singular": {
                            "resource_type": "test",
                            "name": "nested_singular",
                            "original_file_path": "models/marts/assert_parent.sql",
                            "depends_on": {"nodes": ["model.proj.parent"]},
                        },
                        "test.proj.dead_generic": {
                            "resource_type": "test",
                            "name": "dead_generic",
                            "original_file_path": "models/schema.yml",
                            "test_metadata": {"name": "not_null"},
                            "depends_on": {"nodes": ["model.proj.dead"]},
                        },
                    },
                    "sources": {},
                    "exposures": {},
                    "child_map": {
                        "model.proj.dead": ["test.proj.dead_generic"],
                        "model.proj.synced": [],
                        "model.proj.parent": [
                            "model.proj.child",
                            "test.proj.nested_singular",
                        ],
                        "model.proj.child": [],
                        "model.proj.tested_only": ["test.proj.tested_only_singular"],
                    },
                }
            )
        )

    def test_scores_dead_synced_declared_and_observed_models(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "manifest.json"
            self.manifest(manifest_path)
            models, _ = MODULE.load_manifest(manifest_path)
        rows = [
            {"relation_name": name, "observed_days": "90"}
            for name in models
        ]
        for row in rows:
            if row["relation_name"] == "cat.analytics.child":
                row.update(
                    {
                        "external_reads": "12",
                        "known_consumer_reads": "10",
                        "unknown_consumer_reads": "2",
                        "distinct_readers": "3",
                        "last_external_read": "2026-07-18T00:00:00Z",
                    }
                )
        scored = {item.name: item for item in MODULE.score_models(models, rows, 90)}
        self.assertEqual("CANDIDATE_DEAD", scored["dead"].classification)
        self.assertEqual(85, scored["dead"].dead_confidence)
        self.assertEqual(
            "SERVINGDB_ONLY_UNVERIFIED", scored["synced"].classification
        )
        self.assertEqual(60, scored["synced"].dead_confidence)
        self.assertEqual("LIVE_DECLARED", scored["parent"].classification)
        self.assertEqual("LIVE_OBSERVED", scored["child"].classification)
        self.assertEqual("LIVE_DECLARED", scored["tested_only"].classification)
        self.assertEqual(0, scored["tested_only"].dead_confidence)

    def test_sql_is_read_only_and_contains_exclusions(self) -> None:
        sql = MODULE.build_usage_sql(
            ["cat.analytics.dead"], 90, ["dbt"], ["svc-dbt"], ["pipeline-1"]
        )
        self.assertIn("`system`.`query`.`history`", sql)
        self.assertIn("('cat.analytics.dead')", sql)
        self.assertIn("'svc-dbt'", sql)
        self.assertIn("'pipeline-1'", sql)
        self.assertLess(
            sql.index("DASHBOARD_V3"),
            sql.index("q.statement_id IS NULL"),
        )
        self.assertIn(
            "WHEN q.statement_id IS NULL THEN 'UNKNOWN_CONSUMER'",
            sql,
        )
        self.assertNotRegex(sql, r"(?im)^\s*(DELETE|DROP|MERGE|INSERT|UPDATE)\b")

    def test_rejects_unsafe_relation_and_lookback(self) -> None:
        with self.assertRaises(ValueError):
            MODULE.build_usage_sql(["cat.schema.x'; DROP TABLE x"], 90, [], [], [])
        with self.assertRaises(ValueError):
            MODULE.build_usage_sql(["cat.schema.safe"], 366, [], [], [])

    def test_usage_json_must_be_array_of_objects(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "usage.json"
            path.write_text('{"relation_name": "cat.analytics.dead"}')
            with self.assertRaises(ValueError):
                MODULE.load_usage_rows(path)
            path.write_text('[{"external_reads": 1}]')
            with self.assertRaises(ValueError):
                MODULE.load_usage_rows(path)
            path.write_text('[{"relation_name": "cat.analytics.dead", "external_reads": 1}]')
            rows = MODULE.load_usage_rows(path)
            self.assertEqual(1, len(rows))
            path.write_text('[{"relation_name": 123}]')
            with self.assertRaises(TypeError):
                MODULE.load_usage_rows(path)
            with self.assertRaises(TypeError):
                MODULE.relation_key(123)
            with self.assertRaises(ValueError):
                MODULE.score_models(
                    {"cat.analytics.dead": models_stub()},
                    [{"relation_name": ""}],
                    90,
                )


def models_stub() -> dict:
    return {
        "unique_id": "model.proj.dead",
        "node": {
            "name": "dead",
            "original_file_path": "models/dead.sql",
            "config": {"meta": {}},
        },
        "dbt_dependents": 0,
        "exposures": 0,
    }


class ResultPaginationTests(unittest.TestCase):
    def test_falls_back_to_total_chunk_count(self) -> None:
        calls: list[str] = []

        def fake_api(method: str, path: str, profile: str | None, body=None):
            calls.append(path)
            self.assertEqual("get", method)
            return {
                "chunk_index": 1,
                "data_array": [["cat.analytics.two"]],
            }

        original = MODULE.databricks_api
        MODULE.databricks_api = fake_api
        try:
            rows = MODULE.rows_from_response(
                {
                    "statement_id": "stmt-1",
                    "manifest": {
                        "total_chunk_count": 2,
                        "schema": {"columns": [{"name": "relation_name"}]},
                    },
                    "result": {
                        "chunk_index": 0,
                        "data_array": [["cat.analytics.one"]],
                    },
                },
                None,
            )
        finally:
            MODULE.databricks_api = original
        self.assertEqual(
            ["cat.analytics.one", "cat.analytics.two"],
            [row["relation_name"] for row in rows],
        )
        self.assertEqual(
            ["/api/2.0/sql/statements/stmt-1/result/chunks/1"],
            calls,
        )


if __name__ == "__main__":
    unittest.main()
