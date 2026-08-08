{% test raw_stage_row_conservation(model, source_name, source_table, partition_column='release_date') %}
{#
    Tier 1 (error): raw row counts must equal staging row counts.

    For near-passthrough staging models (no intentional grain change), every
    raw row must survive into staging. Compared per partition_column (default
    release_date) so a single bad file cannot hide behind another release.

    Does NOT apply to models that intentionally change grain (e.g. PAYOR_B MAO
    encounter collapse) — those keep dedicated singular conservation tests.

    Usage in _schema.yml
    --------------------
        data_tests:
          - raw_stage_row_conservation:
              arguments:
                source_name: payor
                source_table: raw_uhc_claims
                partition_column: release_date
              config:
                severity: error
                tags: ["payor", "reconciliation", "conservation"]
#}
{{ config(severity='error') }}

with raw_counts as (
    select
        try_cast({{ partition_column }} as date) as partition_key,
        count(*) as n_raw
    from {{ source(source_name, source_table) }}
    group by 1
),

stg_counts as (
    select
        try_cast({{ partition_column }} as date) as partition_key,
        count(*) as n_stg
    from {{ model }}
    group by 1
)

select
    coalesce(r.partition_key, s.partition_key) as {{ partition_column }},
    coalesce(r.n_raw, 0) as n_raw,
    coalesce(s.n_stg, 0) as n_stg,
    coalesce(r.n_raw, 0) - coalesce(s.n_stg, 0) as variance
from raw_counts r
full outer join stg_counts s
    on r.partition_key <=> s.partition_key
where coalesce(r.n_raw, 0) <> coalesce(s.n_stg, 0)

{% endtest %}
