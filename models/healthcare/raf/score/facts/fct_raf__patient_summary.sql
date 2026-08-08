{{
  config(
    materialized='table',
    schema='healthcare',
    tags=['raf', 'gold', 'fact', 'cube', 'BIPlatform']
  )
}}

/*
  Fact: RAF Patient Summary

  Replaces: RAF_MONTHLY_2025 (81K) + RAF_MONTHLY_2026 (14K)
           + RAF_PATIENT_MONTHLY_TOTAL (UNION view)

  Per-patient RAF with closed/open/potential breakdowns.
  Includes demographic-only members (zero HCC coefficient).

  MATERIALIZATION (2026-06 raf_staging eradication / population determinism):
    Previously an incremental MERGE keyed on (patient_id, payment_year) with no
    delete logic. Because the merge never removed keys absent from the source,
    members who dropped out of the active population were retained run-over-run
    — the "12k graveyard" that inflated the scored-member count above the true
    active population. The driving dim_raf__attribution is already a full-rebuild
    table and this fact always recomputes every payment year, so a full TABLE
    rebuild is both deterministic and graveyard-free (matching the sibling
    fct_raf__frs_summary / dim_raf__attribution materializations). This is the
    repo-consistent equivalent of an insert_overwrite-by-payment_year refresh.

  Payment RAF calculation:
    Payment_RAF = (Raw_RAF / normalization_factor) × (1 - coding_intensity)

  Where for PY2025 V28: normalization=1.067, coding_intensity=0.0590
  MSSP populations do NOT receive coding intensity adjustment.
*/

with score_components as (
    select * from {{ ref('fct_raf__score_components') }}
),

normalization as (
    select * from {{ ref('ref_raf__normalization_factors') }}
),

-- Governed scoreable payment years: the prospective payment_year ->
-- diagnosis_coded_year map. Only payment years with a complete prior-year
-- diagnosis basis (given the Oct-2024 EMR data inception) are scoreable -- PY2026
-- onward. This is the single managed source of truth for the year axis and the
-- payment-vs-diagnosis-year distinction.
scoreable_years as (
    -- One row per payment_year (the seed is 1:1 payment_year -> diagnosis_coded_year
    -- and unique-tested, but aggregate defensively so neither join below can fan out
    -- patient-years if the seed grain ever changes).
    select
        payment_year,
        max(diagnosis_coded_year) as diagnosis_coded_year
    from {{ ref('ref_raf__data_collection_periods') }}
    where is_scoreable = true
    group by payment_year
),

-- All patients with attribution (including those with no HCC scores).
-- Gated to scoreable payment years so the demographic-only PY2024/PY2025 shells --
-- artifacts of attribution spanning calendar years the scoring engine never ran --
-- no longer leak into the scored fact.
attribution as (
    select distinct
        a.entity_id,
        a.patient_id,
        a.identity_id,
        a.is_ghost,
        a.payment_year
    from {{ ref('dim_raf__attribution') }} a
    inner join scoreable_years sy
        on a.payment_year = sy.payment_year
    where a.is_active = true
),

-- FIX D5: Identify MSSP-attributed patients from Medicare attribution data.
-- MSSP patients should NOT receive the MA coding intensity adjustment (5.90%).
-- CMS: ACO REACH / MSSP populations use their own coding intensity factor.
-- Source: empi_medicare_matches partitioned by attr_report_period.
mssp_patients as (
    select distinct
        cast(athena_patient_id as bigint) as patient_id
    from {{ source('healthcare', 'empi_medicare_matches') }}
    where approval_status in ('auto_approved', 'manually_approved')
      -- Use the most recent attribution snapshot rather than a hardcoded period.
      -- The prior hardcode ('2025-12') pinned MSSP identification to a stale
      -- 20-patient snapshot; the current snapshot ('2026-04') covers 868. Taking
      -- max(attr_report_period) self-advances as new attribution data lands and
      -- keeps the MA coding-intensity skip aligned to current MSSP attribution.
      and attr_report_period = (
          select max(attr_report_period)
          from {{ source('healthcare', 'empi_medicare_matches') }}
          where approval_status in ('auto_approved', 'manually_approved')
      )
),

-- Join scores with normalization
patient_summary as (
    select
        coalesce(sc.entity_id, a.entity_id)               as entity_id,
        coalesce(sc.patient_id, a.patient_id)             as patient_id,
        coalesce(sc.identity_id, a.identity_id)           as identity_id,
        coalesce(sc.is_ghost, a.is_ghost)                 as is_ghost,
        coalesce(sc.coded_year, a.payment_year)            as payment_year,
        -- Prospective CMS-HCC distinction made explicit: the diagnosis (date-of-
        -- service) year whose coded conditions produced this payment year's score.
        -- PY2026 is scored from CY2025 diagnoses. Sourced from the governed
        -- ref_raf__data_collection_periods seed.
        sy.diagnosis_coded_year                            as diagnosis_coded_year,
        sc.eligibility_segment,
        -- Component breakdown
        coalesce(sc.demographic_factor, 0)                 as demographic_factor,
        coalesce(sc.disease_factor, 0)                     as disease_factor,
        coalesce(sc.interaction_factor, 0)                 as interaction_factor,
        coalesce(sc.count_factor, 0)                       as count_factor,
        coalesce(sc.raw_raf_score, 0)                      as raw_raf_score,
        coalesce(sc.distinct_hcc_count, 0)                 as distinct_hcc_count,
        -- Demographics
        sc.age,
        sc.sex_code,
        sc.age_band,
        -- MSSP flag
        case when mssp.patient_id is not null then true else false end as is_mssp,
        -- Normalization
        coalesce(n.normalization_factor, 1.067)            as normalization_factor,
        -- FIX D5: MSSP patients do NOT receive MA coding intensity adjustment.
        -- MA patients receive the standard 5.90% CIF per CMS Rate Announcement.
        case
            when mssp.patient_id is not null then 0
            else coalesce(n.coding_intensity_adjustment, 0.0590)
        end                                                as coding_intensity_factor,
        -- Payment RAF calculation
        -- FIX D3: Demographic-only patients (raw_raf > 0 from demographic factor alone)
        --         still receive a payment RAF. Previous logic zeroed them out.
        -- FIX D5: MSSP populations skip the 5.90% MA coding intensity adjustment.
        -- CMS: "demographic risk score can serve as predicted expenditure
        --        levels for people with zero HCCs"
        case
            when coalesce(sc.raw_raf_score, 0) = 0 then 0
            when mssp.patient_id is not null
                then coalesce(sc.raw_raf_score, 0) / coalesce(n.normalization_factor, 1.067)
            else (coalesce(sc.raw_raf_score, 0) / coalesce(n.normalization_factor, 1.067))
                 * (1 - coalesce(n.coding_intensity_adjustment, 0.0590))
        end                                                as payment_raf_score,
        -- Flags
        -- Demographic-only = score has no disease/interaction/count contribution.
        -- Covers both zero-HCC members AND New Enrollees (forced demographic-only
        -- upstream in fct_raf__score_components per CMS methodology).
        case
            when sc.entity_id is null then true
            when coalesce(sc.disease_factor, 0)
               + coalesce(sc.interaction_factor, 0)
               + coalesce(sc.count_factor, 0) = 0 then true
            else false
        end                                                as is_demographic_only,
        cast(make_date(coalesce(sc.coded_year, a.payment_year), 1, 1) as timestamp) as calculated_at
    from attribution a
    left join score_components sc
        on a.entity_id = sc.entity_id
        and a.payment_year = sc.coded_year
    left join scoreable_years sy
        on a.payment_year = sy.payment_year
    left join normalization n
        on coalesce(sc.coded_year, a.payment_year) = n.payment_year
    left join mssp_patients mssp
        on coalesce(sc.patient_id, a.patient_id) = mssp.patient_id
)

select * from patient_summary
