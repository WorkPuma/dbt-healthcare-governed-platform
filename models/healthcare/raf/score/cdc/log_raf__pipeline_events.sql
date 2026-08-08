{{
  config(
    materialized='incremental',
    unique_key='event_id',
    incremental_strategy='append',
    on_schema_change='append_new_columns',
    schema='healthcare',
    tags=['raf', 'cdc', 'audit', 'pipeline'],
    full_refresh=false
  )
}}

/*
  Pipeline Event Log: Technical Pipeline Execution Tracking

  Append-only log of every RAF pipeline execution with timing,
  record counts, and outcome. Written by the Prefect orchestrator
  via Databricks SQL after each dbt run completes.

  GRAIN: one row per pipeline execution event

  Event Types:
    PIPELINE_STARTED       - Orchestrator begins pre-flight checks
    PREFLIGHT_PASSED       - All pre-flight validations succeeded
    PREFLIGHT_FAILED       - One or more pre-flight checks failed
    DBT_RUN_STARTED        - Databricks dbt job triggered
    DBT_RUN_COMPLETED      - dbt run finished successfully
    DBT_RUN_FAILED         - dbt run failed (rollback initiated)
    SNAPSHOT_CREATED       - Delta version snapshot recorded
    ROLLBACK_INITIATED     - Rolling back to prior Delta versions
    ROLLBACK_COMPLETED     - Rollback finished
    SERVICE_BUS_PUBLISHED  - raf-scores-ready message published
    LOCK_ACQUIRED          - Pipeline lock obtained
    LOCK_RELEASED          - Pipeline lock freed
    SEED_VALIDATION_PASSED - SHA-256 seed checksums verified
    SEED_VALIDATION_FAILED - Seed checksum mismatch detected

  Population:
    This table is populated by the Prefect orchestrator
    (raf_pipeline_orchestrator.py) via direct INSERT statements
    using databricks-sql-connector. It is NOT populated by dbt
    itself -- dbt only reads it for monitoring/reporting.

  Best Practice (Tavily research 2025):
    - Append-only with delta.appendOnly = 'true' at table level
    - Time-partitioned for efficient scans
    - 90-day retention via Delta log properties
    - Immutable: no UPDATE or DELETE operations
*/

-- This model defines the schema. Rows are inserted externally by Prefect.
-- The incremental filter ensures dbt never truncates existing data.

{% if is_incremental() %}

    -- On incremental runs, select nothing new (Prefect inserts directly)
    select
        cast(null as string)        as event_id,
        cast(null as timestamp)     as event_timestamp,
        cast(null as string)        as event_type,
        cast(null as string)        as run_id,
        cast(null as string)        as trigger_source,
        cast(null as string)        as trigger_message_id,
        cast(null as string)        as dbt_invocation_id,
        cast(null as string)        as databricks_run_id,
        cast(null as int)           as records_processed,
        cast(null as int)           as patients_affected,
        cast(null as double)        as duration_seconds,
        cast(null as string)        as status,
        cast(null as string)        as error_message,
        cast(null as string)        as error_type,
        cast(null as string)        as prefect_flow_run_id,
        cast(null as string)        as prefect_flow_run_url,
        cast(null as string)        as environment,
        cast(null as string)        as metadata_json
    where 1 = 0  -- Never return rows on incremental; Prefect handles inserts

{% else %}

    -- Full refresh: create empty table with correct schema
    select
        cast(null as string)        as event_id,
        cast(null as timestamp)     as event_timestamp,
        cast(null as string)        as event_type,
        cast(null as string)        as run_id,
        cast(null as string)        as trigger_source,
        cast(null as string)        as trigger_message_id,
        cast(null as string)        as dbt_invocation_id,
        cast(null as string)        as databricks_run_id,
        cast(null as int)           as records_processed,
        cast(null as int)           as patients_affected,
        cast(null as double)        as duration_seconds,
        cast(null as string)        as status,
        cast(null as string)        as error_message,
        cast(null as string)        as error_type,
        cast(null as string)        as prefect_flow_run_id,
        cast(null as string)        as prefect_flow_run_url,
        cast(null as string)        as environment,
        cast(null as string)        as metadata_json
    where 1 = 0  -- Empty schema-only table

{% endif %}
