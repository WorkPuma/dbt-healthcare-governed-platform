{% test raw_source_loader_grain(model, source_column='source', release_column=none) %}
{#
    Tier 1 (error): each Prefect load key must appear once in a raw table.

    The payor loader deletes-then-inserts by `source` (filename), and for CMS
    single-period feeds also by release_date. This test fails when the same
    (source [, release_date]) key has been loaded more than once without the
    prior slice being replaced — the exact class of defect that duplicated
    PAYOR_B claim rows before the atomic MERGE fix.

    Applied on source tables (model = source relation via schema.yml tests on
    sources) or any relation that carries the loader metadata columns.

    Usage on a source table in _sources.yml
    ---------------------------------------
        tables:
          - name: raw_payor_alpha_summary
            data_tests:
              - raw_source_loader_grain:
                  arguments:
                    source_column: source
                  config:
                    severity: error
                    tags: ["payor", "reconciliation", "loader_grain"]
#}
{# Default warn: many payor raw tables still carry pre-MERGE duplicate
   loaded_at batches. Escalate to error per-source once that feed is remedi-
   ated (raw_uhc_claims / raw_uhc_control_totals already do). #}
{{ config(severity='warn') }}

with keyed as (
    select
        coalesce(nullif(trim(cast({{ source_column }} as string)), ''), '(unknown)') as load_source
        {%- if release_column %}
        , try_cast({{ release_column }} as date) as load_release
        {%- endif %}
        , count(*) as n_rows
        , count(distinct cast(loaded_at as string)) as n_load_batches
    from {{ model }}
    group by 1{% if release_column %}, 2{% endif %}
)

-- A single load_key with multiple distinct loaded_at batches indicates the
-- idempotent replace failed and rows from two writes co-exist.
select
    load_source
    {%- if release_column %}
    , load_release
    {%- endif %}
    , n_rows
    , n_load_batches
from keyed
where n_load_batches > 1

{% endtest %}
