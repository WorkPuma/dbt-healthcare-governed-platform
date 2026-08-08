# dbt healthcare governed platform

A functional example of the dbt metric platform I built for a Medicare Advantage provider. 500+ models on Databricks, governed metric registries, automated data contracts, and a CI gate that treats human and AI agent pull requests identically.

No proprietary data, patient information, or organization-specific details are included. Models and seeds use de-identified, generic, or publicly available reference data (CMS HCC coefficients, etc.).

## What this shows

The platform solves three problems:

1. **Metric governance.** A metric registry built from dbt seeds binds every metric name to its mart column, aggregation, and grain. The registry is the authority. Dashboards read the registry, not ad-hoc SQL.
2. **CI/CD enforcement.** CircleCI runs compile, test, contract validation, and CodeAnt review on every PR. Both human developers and autonomous agents submit PRs on `agent/*` branches. Same gate. No autonomous merge to main.
3. **Human in the loop.** Agents write code, run tests, open PRs. A human reviews and merges. Always.

## Built with

- [dbt Core](https://github.com/dbt-labs/dbt-core) (MIT) for SQL transformation, incremental models, data contracts, and the semantic layer
- [Databricks Lakehouse](https://www.databricks.com/) for Delta Lake storage with Change Data Feed and incremental MERGE
- [CircleCI](https://circleci.com/) for the CI/CD pipeline (slim-ci, full-refresh guards, seed integrity, MDM compliance)
- [Elementary](https://www.elementary-data.com/) for dbt data observability and test monitoring

This pattern works with organizations running AgenticAI development workflows. The CI gate catches breaking changes from autonomous agents the same way it catches them from human developers.

## Patterns in this repo

**Governed metric registry.** The `metric_definitions` seed drives BI calculations. `mart_relationships` defines upstream and downstream dependencies. Every mart declares its grain in `ref_mart_grains`. Contract enforcement lives in the `_mart_*__model.yml` files.

**Incremental CDC.** RAF scoring uses append-only CDC logs (`log_raf__score_events`, `log_raf__pipeline_events`). The `smart_incremental_filter` macro optimizes incremental merges. Full-refresh is disabled at the project level to protect Change Data Feed.

**Data contracts.** `dbt-bouncer.yml` enforces naming conventions, documentation requirements, and test coverage. Custom manifest checks validate source dependencies. Contract seeds are hash-locked in CI so unauthorized seed changes fail the build.

**CI/CD gate.** Slim CI on PRs (compile and test only, no database writes). Full-refresh guard prevents accidental `--full-refresh`. Seed integrity guard detects hash changes in reference seeds. MDM compliance checks validate master data source dependencies. Nightly quality gate runs Elementary plus source freshness.

**Healthcare-specific.** CMS HCC coefficient tables (V24, V28, V28.1, ESRD) for risk adjustment scoring. HEDIS quality measure funnel from staging through marts. Multi-source joins across EHR and CRM reference data. SCD2 historical layer for retrospective analysis.

## Project structure

```
dbt_project.yml              Project config with full-refresh protection
packages.yml                 Dependencies (Elementary, dbt_date, dbt_expectations)
dbt-bouncer.yml              Manifest validation rules
.circleci/
  config.yml                 CI/CD pipeline
macros/                      Reusable Jinja macros
  governance/                MDM compliance
  raf/                       HCC scoring (coefficient lookup, demographic risk)
models/
  sources/                   Staging views over raw sources
  intermediate/              Cross-schema business logic
  healthcare/
    quality/                 HEDIS quality measure funnel
    raf/                     Risk adjustment (staging, intermediate, CDC, scoring)
  dimensions/                Conformed dimensions
  facts/                     Canonical business events
  marts_bi_v3/               V3 metric registry mart layer
  mdm/                       MDM incremental sync models
  semantic_models/           MetricFlow semantic definitions
seeds/
  cms_hcc_v28/               CMS-HCC V28 coefficients (public CMS data)
  cms_hcc_v24/               CMS-HCC V24 coefficients (public CMS data)
  cms_hcc_v28_1/             CMS-HCC V28.1 coefficients (public CMS data)
  cms_hcc_esrd/              CMS-HCC ESRD coefficients (public CMS data)
  raf_reference/             Risk adjustment reference tables
  claims_reference/          Claims reference data
  marts_bi_v3/               Metric registry definitions
  audit/                     Consolidation ledger and model contracts
scripts/                     CI validators
  check_consolidation_ledger.py
  check_mdm_compliance.py
  audit_dead_models.py
  check_ci_isolation_safety.py
tests/                       Custom SQL and Python tests
custom_checks/               Manifest-level validation checks
```

## Credit and licensing

- **dbt Core** by dbt Labs, MIT License
- **Databricks Lakehouse Platform** by Databricks Inc.
- **CircleCI** by Circle Internet Services
- **Elementary** by Elementary Data

All CMS HCC coefficient data is publicly available from the Centers for Medicare and Medicaid Services. No proprietary clinical algorithms, organization-specific logic, or patient data is included.

## License

MIT
