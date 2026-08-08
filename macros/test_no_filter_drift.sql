{% test no_filter_drift(model, key_column, source_model=none, source_database=none, source_schema=none, source_identifier=none, source_key_column=none, target_filter=none, max_age_days=none, age_column=none, latest_snapshot_column=none) %}
{#
    Detects rows in an incremental-merge model that no longer exist in the
    upstream source the model is built from -- i.e., rows that should have
    been filtered out (or were deleted upstream) but were never DELETED from
    the target because dbt MERGE only handles INSERT/UPDATE.

    This is the classic "dbt MERGE doesn't delete rows that no longer match
    the filter" drift. It silently inflates dimensions and facts and is
    invisible to row counts that look reasonable.

    Compares: target unique key vs upstream filtered population.
    Returns:  one row per orphaned key (test fails when any are present).

    Parameters
    ----------
    key_column        Unique key column on the model under test (target side).
    source_model      Optional. dbt model name to compare against (uses ref()).
    source_database / source_schema / source_identifier
                      Optional. Direct three-part relation when the upstream
                      is not a dbt-managed model (e.g. an MDM source view).
                      All three must be provided together.
    source_key_column Optional. Override the source-side key when it differs
                      from `key_column`.
    target_filter     Optional. Extra WHERE predicate applied on the target
                      side to scope the test (e.g. "discharge_date IS NOT NULL"
                      to skip aggregation roll-ups). Named `target_filter`
                      instead of `where` to avoid colliding with dbt's
                      built-in `where` config that wraps the model in a
                      subquery via `get_where_subquery`.
    max_age_days      Optional. When set together with `age_column`, restricts
                      drift detection to phantom rows whose `age_column`
                      timestamp is OLDER than `max_age_days` from now. This
                      excludes rows that are transiently orphaned because (a)
                      the nightly quality-gate runs tests only (no model
                      build, so the post_hook phantom cleanup never fires) or
                      (b) the model's post_hook deliberately protects recently-
                      loaded rows inside a known transient window (e.g. the
                      7-day `last_matched_at` guard on patient_identity).
                      Without a watermark, every phantom -- including rows
                      the cleanup intentionally preserves -- trips the test,
                      producing chronic warn noise during test-only runs.
                      Set the watermark to match (or exceed) the model's
                      post_hook transient guard so only genuinely stranded
                      drift is reported. Leave unset to preserve the original
                      all-phantom behavior.
    age_column        Optional. Target-side timestamp column used by
                      `max_age_days` to compute phantom age. Typically the
                      same watermark column the post_hook cleans on
                      (e.g. last_matched_at, source_updated_at, last_updated_at).
    latest_snapshot_column
                      Optional. Target-side date/timestamp column whose MAX
                      value defines the "current" snapshot. When set, drift
                      detection is scoped to rows where the column equals the
                      target's own MAX(<column>). Use this for daily-snapshot
                      / accumulating-snapshot facts (e.g. patient_census keyed
                      on (entity_id, snapshot_date)) that legitimately retain
                      historical rows for patients who have since been merged
                      or removed upstream. Without this scope the test would
                      flag every historical row whose patient_id no longer
                      exists in the current-state source dimension, producing
                      false drift noise that grows monotonically. Scoping to
                      the latest snapshot means only genuinely missing keys in
                      the CURRENT population trip the test — the same semantics
                      the test has for a current-state dimension. Leave unset
                      to preserve the original all-rows behavior (correct for
                      current-state dimensions and append-only facts).

    Usage in _models.yml
    --------------------
        tests:
          # Compare against a dbt model
          - no_filter_drift:
              arguments:
                key_column: patient_id
                source_model: stg_mdm__patient
              config:
                severity: warn
                tags: ["elementary", "filter_drift", "data_quality"]

          # Compare against an external relation (MDM source view)
          - no_filter_drift:
              arguments:
                key_column: patient_id
                source_database: mdm
                source_schema: reference_data
                source_identifier: v_patient_sync
              config:
                severity: warn
                tags: ["elementary", "filter_drift", "data_quality"]

          # With a transient-window watermark (excludes build-lag phantoms)
          - no_filter_drift:
              arguments:
                key_column: golden_id
                source_model: int_empi_golden_records_clean
                max_age_days: 7
                age_column: last_matched_at
              config:
                severity: warn
                tags: ["elementary", "filter_drift", "data_quality"]

          # Scoped to the latest snapshot (daily-snapshot fact that retains
          # historical rows for merged/removed upstream keys)
          - no_filter_drift:
              arguments:
                key_column: patient_id
                source_model: patients
                target_filter: "patient_id is not null and is_ghost = false"
                latest_snapshot_column: snapshot_date
              config:
                severity: warn
                tags: ["elementary", "filter_drift", "data_quality"]
#}

{%- if source_model is none and source_identifier is none -%}
    {{ exceptions.raise_compiler_error(
        "no_filter_drift: must provide either `source_model` or `source_database`+`source_schema`+`source_identifier`"
    ) }}
{%- endif -%}

{%- set source_relation -%}
    {%- if source_model is not none -%}
        {{ ref(source_model) }}
    {%- else -%}
        {{ adapter.get_relation(database=source_database, schema=source_schema, identifier=source_identifier) }}
    {%- endif -%}
{%- endset -%}

{%- set src_key = source_key_column or key_column -%}

select
    t.{{ key_column }} as orphan_key
from {{ model }} t
where not exists (
    select 1
    from {{ source_relation }} s
    where s.{{ src_key }} = t.{{ key_column }}
)
{% if target_filter %}
  and ({{ target_filter }})
{% endif %}
{% if max_age_days is not none and age_column is not none %}
  {%- if max_age_days|int < 0 -%}
    {{ exceptions.raise_compiler_error(
        "no_filter_drift: max_age_days must be a non-negative integer (got " ~ max_age_days ~ "). "
        ~ "A negative value inverts the watermark and would hide genuinely stranded drift."
    ) }}
  {%- endif %}
  and t.{{ age_column }} is not null
  and t.{{ age_column }} < current_timestamp() - INTERVAL {{ max_age_days }} DAYS
{% endif %}
{% if latest_snapshot_column is not none %}
  and t.{{ latest_snapshot_column }} = (
      select max(t2.{{ latest_snapshot_column }})
      from {{ model }} t2
  )
{% endif %}

{% endtest %}
