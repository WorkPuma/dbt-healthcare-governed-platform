-- DEV-4296 · int_quality__code_pool (V3 Databricks dbt)
-- This is NOT hedis evidence — it grabs
-- ALL athena clinical codes. The TRUE hedis evidence is the QM-engine sidecar that now owns
-- the int_quality__hedis_evidence name.
--
-- THE unified payor-agnostic CODE POOL: one row per patient × code × code_type × date_of_service.
-- UNION ALL of the per-branch intermediates. code_type is a COLUMN (never a separate table).
-- Best-evidence ranking / exclusions / payer code-list / measure assignment = DOWNSTREAM, not here.
-- Materialization: incremental TABLE (P10 multi-consumer: downstream payer sidecars).
-- M9: incremental merge + matched_condition (update a grain row when its source set OR its
--     content — order_status / evidence_provenance / code_raw — changes).
-- COMPUTE (storage grows with years, compute-per-run does not):
--   * incremental: only reprocess the recent delta each run (mechanism #1).
--   * rolling lookback window caps the STORED pool at ~10y (longest HEDIS lookback, COL) so a
--     full-refresh never rescans the entire EMR (mechanism #2).
--   * the measurement-year (2026) filter is a CONSUMER/sidecar concern, applied downstream with
--     per-measure lookback — NEVER a blanket year() filter here (would drop valid lookback codes).
-- DEV-4300: int_quality__problem_code_evidence IS now unioned below — the
--     SPECIALIZED EXCLUSION FUNNEL (payer-agnostic, HEDIS exclusion value-sets only, soft provenance).
--     patientproblem is live in athenahealth.athenaone (Databricks Delta); the federation block that
--     deferred this branch no longer applies. Patient resolved via AP-016 chart-hop.

{{ config(
    materialized        = 'incremental',
    incremental_strategy = 'merge',
    unique_key          = 'evidence_key',
    on_schema_change    = 'append_new_columns',
    matched_condition   = 'not (t.source_hits <=> s.source_hits) or not (t.order_status <=> s.order_status) or not (t.evidence_provenance <=> s.evidence_provenance) or not (t.code_raw <=> s.code_raw) or not (t.code_modifier <=> s.code_modifier) or not (t.source_tables <=> s.source_tables) or not (t.measurement_year <=> s.measurement_year) or not (t.code_origin <=> s.code_origin) or not (t.source_methods <=> s.source_methods) or not (t.create_date <=> s.create_date)'
) }}

{%- set pool_cols -%}
    patient_id, code, code_type, date_of_service, code_raw, code_modifier,
    source_table, measurement_year, code_origin, source_method, order_status, evidence_provenance, create_date
{%- endset -%}
-- EXPLICIT column union (NOT select *): the lab branch carries 2 extra cols
-- (result_reported_date, reporting_lag_days) for turnaround analysis — those stay in
-- lab_code_evidence and are intentionally NOT pulled into the pool. order_status IS carried.
with pool as (
    select {{ pool_cols }} from {{ ref('int_quality__encounter_code_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__service_code_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__lab_code_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__surgical_code_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__surgery_code_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__claim_code_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__charge_code_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__questionnaire_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__document_evidence') }}
    union all
    select {{ pool_cols }} from {{ ref('int_quality__problem_code_evidence') }}
    {#- union all select ... from ref('int_quality__hh_added_evidence') -- [HH-ADDED] NLP (deferred) -#}
),

{% if is_incremental() %}
filtered as (
    select * from pool
    where date_of_service >= (select dateadd(month, -3, max(date_of_service)) from {{ this }})
       or source_method = 'problem_list'
),
{% else %}
filtered as (
    select * from pool
    where date_of_service >= dateadd(year, -10, current_date)
       or source_method = 'problem_list'
),
{% endif %}

deduped as (
    select
        md5(concat_ws('||',
            cast(patient_id as string), code, code_type, cast(date_of_service as string)
        ))                                                          as evidence_key,
        cast(patient_id as string)                                  as patient_id,
        cast(code as string)                                        as code,
        code_type,
        date_of_service,
        cast(min(code_raw) as string)                               as code_raw,
        min(code_modifier)                                          as code_modifier,
        cast(array_distinct(collect_list(source_table)) as array<string>)  as source_tables,
        count(*)                                                    as source_hits,
        max(measurement_year)                                       as measurement_year,
        case
            when max(case when code_origin = 'org_added' then 1 else 0 end) = 1
            then 'org_added'
            else 'system'
        end                                                         as code_origin,
        cast(array_distinct(collect_list(source_method)) as array<string>) as source_methods,
        case when max(case when order_status in ('closed','resulted','submittable') then 1 else 0 end) = 1
             then 'submittable' else 'pending' end                  as order_status,
        min(case evidence_provenance
                when 'billed' then 1
                when 'closed_encounter' then 2
                when 'resulted' then 3
                when 'surgical' then 4
                else 5 end)                                         as provenance_rank,
        min(create_date)                                            as create_date
    from filtered
    group by patient_id, code, code_type, date_of_service
)

select
    evidence_key,
    patient_id,
    code,
    code_type,
    date_of_service,
    code_raw,
    code_modifier,
    source_tables,
    source_hits,
    measurement_year,
    code_origin,
    source_methods,
    order_status,
    case provenance_rank
        when 1 then 'billed'
        when 2 then 'closed_encounter'
        when 3 then 'resulted'
        when 4 then 'surgical'
        else 'soft' end                                             as evidence_provenance,
    create_date
from deduped
where patient_id is not null
