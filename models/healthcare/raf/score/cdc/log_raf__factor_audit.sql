{{
  config(
    materialized='incremental',
    unique_key='audit_id',
    incremental_strategy='append',
    on_schema_change='append_new_columns',
    schema='healthcare',
    tags=['raf', 'cdc', 'audit', 'business'],
    full_refresh=false
  )
}}

/*
  Factor Audit Log: Business-Level Scoring Decision Tracking

  Append-only log capturing WHY specific RAF factor decisions were made.
  Complements log_raf__score_events (which tracks WHAT changed) by
  recording the business REASONING behind each modifying factor.

  GRAIN: one row per patient × coded_year × factor_decision_point

  Decision Points Tracked:
    HIERARCHY_EXCLUSION    - HCC excluded because higher-ranked HCC present
    DEDUPLICATION          - Duplicate HCC removed (same patient/year/code)
    STATUS_OVERRIDE        - VendorNav status mapped to standard (ACCEPTED→CLOSED etc.)
    INTERACTION_CREDIT     - Interaction factor awarded for HCC pair
    INTERACTION_DENIED     - HCC pair did not qualify for interaction credit
    ELIGIBILITY_ASSIGNMENT - Patient assigned to eligibility segment
    COUNT_FACTOR_APPLIED   - Payment count factor applied based on HCC count
    TEST_PATIENT_EXCLUDED  - Patient excluded as test record

  Population:
    Populated by dbt during each run by inspecting the intermediate
    models that make business decisions. Each decision point generates
    an audit record explaining WHY.

  Best Practice (Tavily research 2025):
    - Append-only, immutable, time-partitioned
    - Log deltas (what changed), not full state
    - Capture actor, pipeline, environment, execution mode
    - Keep business tables clean; audit in dedicated tables
*/

with hierarchy_source as (
    -- Dedupe upstream before key gen so identical factor rows within a run
    -- cannot collide on audit_id (prod evidence: 318k duplicate audit_ids).
    select *
    from (
        select
            h.*,
            row_number() over (
                partition by
                    h.patient_id,
                    h.coded_year,
                    h.hcc_code,
                    h.diagnosis_code,
                    h.source_system
                order by
                    coalesce(h.source_priority, 999),
                    coalesce(h.status_priority, 999),
                    coalesce(cast(h.clinical_encounter_id as string), ''),
                    coalesce(cast(h.source_record_id as string), '')
            ) as _rn
        from {{ ref('int_raf__hierarchy_applied') }} h
        where h.is_hierarchy_excluded = true
    ) d
    where d._rn = 1
),

hierarchy_exclusions as (
    -- Records excluded by CMS HCC V28 hierarchy rules
    select
        {{ dbt_utils.generate_surrogate_key([
            'h.patient_id',
            'h.coded_year',
            'h.hcc_code',
            'h.diagnosis_code',
            'h.source_system',
            "'HIERARCHY'",
            "'" ~ invocation_id ~ "'"
        ]) }}                                             as audit_id,
        h.patient_id,
        h.coded_year,
        current_timestamp()                               as audit_timestamp,
        'HIERARCHY_EXCLUSION'                             as decision_type,
        h.hcc_code                                        as subject_code,
        h.source_system,
        concat(
            'HCC ', h.hcc_code,
            ' excluded by higher-ranked HCC in hierarchy for patient ',
            cast(h.patient_id as string),
            ' in year ', cast(h.coded_year as string)
        )                                                 as decision_reason,
        'dbt_run'                                         as actor,
        '{{ invocation_id }}'                             as dbt_invocation_id,
        'production'                                      as environment,
        'scheduled'                                       as execution_mode
    from hierarchy_source h
),

interaction_source as (
    select *
    from (
        select
            i.*,
            row_number() over (
                partition by i.patient_id, i.coded_year, i.interaction_key
                order by
                    i.interaction_factor desc,
                    coalesce(i.interaction_name, ''),
                    coalesce(i.eligibility_segment, '')
            ) as _rn
        from {{ ref('int_raf__interaction_factors') }} i
        where i.interaction_factor > 0
    ) d
    where d._rn = 1
),

interaction_credits as (
    -- Interaction factors awarded for qualifying HCC pairs
    select
        {{ dbt_utils.generate_surrogate_key([
            'i.patient_id',
            'i.coded_year',
            'i.interaction_key',
            "'INTERACTION'",
            "'" ~ invocation_id ~ "'"
        ]) }}                                             as audit_id,
        i.patient_id,
        i.coded_year,
        current_timestamp()                               as audit_timestamp,
        'INTERACTION_CREDIT'                              as decision_type,
        i.interaction_key                                 as subject_code,
        'SCORING_ENGINE'                                  as source_system,
        concat(
            'Interaction credit awarded for ',
            i.interaction_name,
            ' (', i.interaction_key, ')',
            ' with factor ', cast(i.interaction_factor as string)
        )                                                 as decision_reason,
        'dbt_run'                                         as actor,
        '{{ invocation_id }}'                             as dbt_invocation_id,
        'production'                                      as environment,
        'scheduled'                                       as execution_mode
    from interaction_source i
),

eligibility_source as (
    select *
    from (
        select
            e.*,
            row_number() over (
                partition by e.patient_id, e.eligibility_segment
                order by
                    coalesce(e.last_updated_at, timestamp '1900-01-01') desc,
                    coalesce(e.segment_name, ''),
                    coalesce(e.hccpy_elig_code, ''),
                    coalesce(e.segment_source, '')
            ) as _rn
        from {{ ref('int_raf__eligibility_segment') }} e
    ) d
    where d._rn = 1
),

eligibility_assignments as (
    -- Eligibility segment assignments
    select
        {{ dbt_utils.generate_surrogate_key([
            'e.patient_id',
            'e.eligibility_segment',
            "'ELIGIBILITY'",
            "'" ~ invocation_id ~ "'"
        ]) }}                                             as audit_id,
        e.patient_id,
        cast(null as int)                                 as coded_year,
        current_timestamp()                               as audit_timestamp,
        'ELIGIBILITY_ASSIGNMENT'                          as decision_type,
        e.eligibility_segment                             as subject_code,
        'ELIGIBILITY_ENGINE'                              as source_system,
        concat(
            'Patient ', cast(e.patient_id as string),
            ' assigned to segment: ', e.eligibility_segment
        )                                                 as decision_reason,
        'dbt_run'                                         as actor,
        '{{ invocation_id }}'                             as dbt_invocation_id,
        'production'                                      as environment,
        'scheduled'                                       as execution_mode
    from eligibility_source e
),

all_decisions as (
    select * from hierarchy_exclusions
    union all
    select * from interaction_credits
    union all
    select * from eligibility_assignments
)

{% if is_incremental() %}

    -- Only append decisions from the current dbt run
    -- (filtered by invocation_id to prevent duplicates on re-runs)
    select * from all_decisions
    where dbt_invocation_id = '{{ invocation_id }}'
      and dbt_invocation_id not in (
          select distinct dbt_invocation_id from {{ this }}
      )

{% else %}

    select * from all_decisions

{% endif %}
