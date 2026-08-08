{{
  config(
    materialized='incremental',
    unique_key='event_id',
    incremental_strategy='append',
    on_schema_change='append_new_columns',
    schema='healthcare',
    tags=['raf', 'cdc', 'audit'],
    full_refresh=false
  )
}}

/*
  CDC Event Log: RAF Score Events

  KEYSTONE OF THE EVENT-DRIVEN ARCHITECTURE (D6)

  Append-only incremental model that captures every RAF-impacting
  change by diffing current int_raf__scored_hccs against
  _log_raf__prior_snapshot at the per-HCC grain.

  GRAIN: one row per patient × coded_year × eligibility_segment × hcc_code × event_type

  Three diff categories:
    1. ADDITIONS  - HCC in current but not in prior (new diagnosis captured)
    2. REMOVALS   - HCC in prior but not in current (diagnosis dropped)
    3. CHANGES    - Same HCC key, different coefficient value (reclassification or correction)

  Event Types:
    DIAGNOSIS_ADD              - New HCC captured from any source
    DIAGNOSIS_REMOVE           - HCC removed (hierarchy, status change, or data correction)
    ELIGIBILITY_RECLASSIFICATION - Same HCC but segment changed, altering coefficient
    COEFFICIENT_CORRECTION     - Coefficient value changed (seed update or recalculation)

  Source Attribution:
    source_system is propagated from int_raf__combined_sources through
    the hierarchy chain. Values: ATHENA, VendorNav, ARCHIVE_2024.
    This enables tracing exactly WHERE a diagnosis originated.

  HARDENING NOTES:
    - full_refresh: false -- prevents accidental truncation of audit trail
    - source_sequence_number -- monotonic ordering per patient/year
    - Processing run ID links to Elementary invocation for traceability
    - _log_raf__prior_snapshot is read via source() (NOT ref()) so dbt
      does NOT rebuild it before this diff runs.  The snapshot model
      depends_on this CDC model and runs AFTER, establishing the
      baseline for the NEXT run.

  Example: "Why did Patient 118749's RAF change in March 2026?"
    SELECT * FROM log_raf__score_events
    WHERE patient_id = 118749
      AND coded_year = 2026
    ORDER BY event_timestamp;
*/

with current_hccs as (
    -- Dedupe to event grain before key gen (prod evidence: 16k duplicate event_ids
    -- from identical upstream rows within a single invocation).
    select *
    from (
        select
            c.*,
            row_number() over (
                partition by
                    c.patient_id,
                    c.coded_year,
                    c.eligibility_segment,
                    c.hcc_code,
                    c.diagnosis_code,
                    c.source_system
                order by
                    coalesce(c.disease_coefficient, 0) desc,
                    coalesce(cast(c.date_of_service as string), ''),
                    coalesce(c.status, ''),
                    coalesce(c.submission_status, ''),
                    coalesce(c.sweep, '')
            ) as _rn
        from {{ ref('int_raf__scored_hccs') }} c
    ) d
    where d._rn = 1
),

prior_snapshot as (
    select *
    from (
        select
            p.*,
            row_number() over (
                partition by
                    p.patient_id,
                    p.coded_year,
                    p.eligibility_segment,
                    p.hcc_code,
                    p.diagnosis_code,
                    p.source_system
                order by
                    coalesce(p.disease_coefficient, 0) desc,
                    coalesce(cast(p.date_of_service as string), ''),
                    coalesce(p.status, ''),
                    coalesce(p.hcc_description, ''),
                    coalesce(cast(p.hcc_code as string), '')
            ) as _rn
        from {{ source('raf_cdc', '_log_raf__prior_snapshot') }} p
    ) d
    where d._rn = 1
),

-- ============================================
-- ADDITIONS: HCC in current but NOT in prior
-- ============================================
additions as (
    select
        {{ dbt_utils.generate_surrogate_key([
            'c.patient_id',
            'c.coded_year',
            'c.eligibility_segment',
            'c.hcc_code',
            'c.diagnosis_code',
            'c.source_system',
            "'ADD'",
            "'" ~ invocation_id ~ "'"
        ]) }}                                             as event_id,
        c.patient_id,
        c.coded_year,
        current_date()                                    as effective_month,
        current_timestamp()                               as event_timestamp,
        'DIAGNOSIS_ADD'                                   as event_type,
        c.source_system,
        'dbt_run'                                         as trigger_entity,
        c.hcc_code,
        c.diagnosis_code                                  as icd10_code,
        'DISEASE'                                         as factor_type,
        cast(0.000000 as double)                          as coefficient_before,
        c.disease_coefficient                             as coefficient_after,
        c.disease_coefficient                             as coefficient_delta,
        c.eligibility_segment,
        'V28'                                             as model_version,
        '{{ invocation_id }}'                             as processing_run_id,
        '{{ invocation_id }}'                             as dbt_invocation_id
    from current_hccs c
    left join prior_snapshot p
        on  c.patient_id = p.patient_id
        and c.coded_year = p.coded_year
        and coalesce(c.eligibility_segment, '__NULL__') = coalesce(p.eligibility_segment, '__NULL__')
        and c.hcc_code = p.hcc_code
    where p.patient_id is null
),

-- ============================================
-- REMOVALS: HCC in prior but NOT in current
-- ============================================
removals as (
    select
        {{ dbt_utils.generate_surrogate_key([
            'p.patient_id',
            'p.coded_year',
            'p.eligibility_segment',
            'p.hcc_code',
            'p.diagnosis_code',
            'p.source_system',
            "'REM'",
            "'" ~ invocation_id ~ "'"
        ]) }}                                             as event_id,
        p.patient_id,
        p.coded_year,
        current_date()                                    as effective_month,
        current_timestamp()                               as event_timestamp,
        'DIAGNOSIS_REMOVE'                                as event_type,
        p.source_system,
        'dbt_run'                                         as trigger_entity,
        p.hcc_code,
        p.diagnosis_code                                  as icd10_code,
        'DISEASE'                                         as factor_type,
        p.disease_coefficient                             as coefficient_before,
        cast(0.000000 as double)                          as coefficient_after,
        -1 * p.disease_coefficient                        as coefficient_delta,
        p.eligibility_segment,
        'V28'                                             as model_version,
        '{{ invocation_id }}'                             as processing_run_id,
        '{{ invocation_id }}'                             as dbt_invocation_id
    from prior_snapshot p
    left join current_hccs c
        on  p.patient_id = c.patient_id
        and p.coded_year = c.coded_year
        and coalesce(p.eligibility_segment, '__NULL__') = coalesce(c.eligibility_segment, '__NULL__')
        and p.hcc_code = c.hcc_code
    where c.patient_id is null
),

-- ============================================
-- CHANGES: same HCC key, different coefficient
-- ============================================
changes as (
    select
        {{ dbt_utils.generate_surrogate_key([
            'c.patient_id',
            'c.coded_year',
            'c.eligibility_segment',
            'c.hcc_code',
            'c.diagnosis_code',
            'c.source_system',
            "'CHG'",
            "'" ~ invocation_id ~ "'"
        ]) }}                                             as event_id,
        c.patient_id,
        c.coded_year,
        current_date()                                    as effective_month,
        current_timestamp()                               as event_timestamp,
        case
            when c.eligibility_segment != p.eligibility_segment then 'ELIGIBILITY_RECLASSIFICATION'
            else 'COEFFICIENT_CORRECTION'
        end                                               as event_type,
        c.source_system,
        'dbt_run'                                         as trigger_entity,
        c.hcc_code,
        c.diagnosis_code                                  as icd10_code,
        'DISEASE'                                         as factor_type,
        p.disease_coefficient                             as coefficient_before,
        c.disease_coefficient                             as coefficient_after,
        c.disease_coefficient - p.disease_coefficient     as coefficient_delta,
        c.eligibility_segment,
        'V28'                                             as model_version,
        '{{ invocation_id }}'                             as processing_run_id,
        '{{ invocation_id }}'                             as dbt_invocation_id
    from current_hccs c
    inner join prior_snapshot p
        on  c.patient_id = p.patient_id
        and c.coded_year = p.coded_year
        and c.hcc_code = p.hcc_code
    where abs(c.disease_coefficient - p.disease_coefficient) > 0.000001
       or coalesce(c.eligibility_segment, '__NULL__') != coalesce(p.eligibility_segment, '__NULL__')
),

-- ============================================
-- UNION ALL diff categories
-- ============================================
all_events as (
    select * from additions
    union all
    select * from removals
    union all
    select * from changes
),

-- ============================================
-- Add source_sequence_number for ordering verification
-- ============================================
with_sequence as (
    select
        *,
        row_number() over (
            partition by patient_id, coded_year
            order by event_timestamp, event_type, hcc_code
        )                                                 as source_sequence_number
    from all_events
)

select * from with_sequence
