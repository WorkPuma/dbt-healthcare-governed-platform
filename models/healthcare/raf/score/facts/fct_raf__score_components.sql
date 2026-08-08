{{
  config(
    materialized='incremental',
    incremental_strategy='merge',
    matched_condition="
        coalesce(t.eligibility_segment, '') <> coalesce(s.eligibility_segment, '')
        OR coalesce(t.distinct_hcc_count, -1) <> coalesce(s.distinct_hcc_count, -1)
        OR coalesce(t.demographic_factor, cast(0 as decimal(18,4))) <> coalesce(s.demographic_factor, cast(0 as decimal(18,4)))
        OR coalesce(t.disease_factor, cast(0 as decimal(18,4))) <> coalesce(s.disease_factor, cast(0 as decimal(18,4)))
        OR coalesce(t.interaction_factor, cast(0 as decimal(18,4))) <> coalesce(s.interaction_factor, cast(0 as decimal(18,4)))
        OR coalesce(t.count_factor, cast(0 as decimal(18,4))) <> coalesce(s.count_factor, cast(0 as decimal(18,4)))
        OR coalesce(t.raw_raf_score, cast(0 as decimal(18,4))) <> coalesce(s.raw_raf_score, cast(0 as decimal(18,4)))
        OR coalesce(t.age, -1) <> coalesce(s.age, -1)
        OR coalesce(t.sex_code, '') <> coalesce(s.sex_code, '')
        OR coalesce(t.age_band, '') <> coalesce(s.age_band, '')
        OR coalesce(t.hcc_details, '') <> coalesce(s.hcc_details, '')
        OR coalesce(t.model_version, '') <> coalesce(s.model_version, '')
    ",
    unique_key=['entity_id', 'coded_year'],
    on_schema_change='append_new_columns',
    schema='healthcare',
    file_format='delta',
    tags=['raf', 'gold', 'fact', 'cube', 'BIPlatform']
  )
}}

/*
  Fact: RAF Score Components

  Replaces: MONTHLY_RAF_ENHANCED (448K rows)

  Column note: output coded_year is aliased from attribution payment_year
  (payment_year AS coded_year). Rename out of scope; disease joins still use
  diagnosis_coded_year from ref_raf__data_collection_periods.

  Per-member, per-year breakdown of every additive RAF score component:
    - Demographic factor (age/sex)
    - Each disease HCC coefficient
    - Interaction factors
    - Payment count factor

  Sum of all components = total raw RAF score.

  Partitioned by coded_year. Year-locked years are immutable.

  CMS Data Collection Period Mapping (CY2026 Implementation Memo):
    PY2026 Initial:       diagnoses from Jul 2024 – Jun 2025
    PY2026 Midyear/Final: diagnoses from Jan 2025 – Dec 2025
  The ref_raf__data_collection_periods seed maps each payment_year to the
  diagnosis coded_year used for scoring, following CMS midyear/final methodology.
*/

with data_collection_periods as (
    -- CMS-mandated mapping: payment_year → diagnosis data collection year.
    -- PY2026 scores off CY2025 diagnoses, not CY2026 (which barely exist yet).
    select * from {{ ref('ref_raf__data_collection_periods') }}
),

scored_hccs as (
    -- Per-HCC scored records from the canonical intermediate model.
    -- Single source of truth shared with CDC (log_raf__score_events).
    select * from {{ ref('int_raf__scored_hccs') }}
),

demographics as (
    select * from {{ ref('int_raf__demographic_factors') }}
),

interactions as (
    select
        patient_id,
        coded_year,
        sum(interaction_factor) as total_interaction_factor
    from {{ ref('int_raf__interaction_factors') }}
    group by patient_id, coded_year
),

count_factors as (
    select * from {{ ref('int_raf__count_factors') }}
),

-- Aggregate disease scores per patient/year
patient_disease_totals as (
    select
        patient_id,
        coded_year,
        eligibility_segment,
        sum(disease_coefficient) as total_disease_coefficient,
        count(distinct hcc_code) as distinct_hcc_count,
        max(hcc_model_version) as model_version,
        to_json(collect_list(struct(hcc_code, disease_coefficient, source_system))) as hcc_details_json
    from scored_hccs
    group by patient_id, coded_year, eligibility_segment
),

-- FIX D3: Drive from demographics spine so demographic-only patients are included.
-- CMS: "The demographic risk score can also serve as predicted expenditure
--        levels for people with zero HCCs."
-- Previously drove from patient_disease_totals, which excluded patients with
-- zero HCCs. Now all patients with demographics get a row.

score_components as (
    select
        d.entity_id,
        d.patient_id,
        d.identity_id,
        d.is_ghost,
        d.payment_year                                    as coded_year,
        coalesce(pdt.eligibility_segment, d.eligibility_segment) as eligibility_segment,
        coalesce(pdt.distinct_hcc_count, 0)               as distinct_hcc_count,
        -- Individual components.
        -- CMS rule: New Enrollees (NE/SNPNE) are scored DEMOGRAPHIC-ONLY -- they
        -- lack 12 months of risk-assessment data, so disease/interaction/count
        -- coefficients do NOT apply regardless of any diagnoses on file.
        coalesce(d.demographic_factor, 0)                 as demographic_factor,
        case when d.is_new_enrollee then 0
             else coalesce(pdt.total_disease_coefficient, 0) end as disease_factor,
        case when d.is_new_enrollee then 0
             else coalesce(i.total_interaction_factor, 0) end as interaction_factor,
        case when d.is_new_enrollee then 0
             else coalesce(cf.count_factor, 0) end        as count_factor,
        -- Raw RAF = sum of all components (demographic-only for new enrollees)
        coalesce(d.demographic_factor, 0)
            + case when d.is_new_enrollee then 0
                   else coalesce(pdt.total_disease_coefficient, 0)
                        + coalesce(i.total_interaction_factor, 0)
                        + coalesce(cf.count_factor, 0) end as raw_raf_score,
        -- Metadata
        d.age,
        d.sex_code,
        d.age_band,
        -- CMS-HCC model version that scored this member-year (Phase 2 stamp;
        -- demographic-only members carry the current model version by default).
        coalesce(pdt.model_version, 'V28')                as model_version,
        pdt.hcc_details_json                              as hcc_details
    from demographics d
    -- CMS data collection period: maps payment_year to the diagnosis year
    -- e.g. PY2026 → diagnosis_coded_year 2025 per CMS midyear/final methodology
    inner join data_collection_periods dcp
        on d.payment_year = dcp.payment_year
    left join patient_disease_totals pdt
        on d.patient_id = pdt.patient_id
        and dcp.diagnosis_coded_year = pdt.coded_year
    left join interactions i
        on d.patient_id = i.patient_id
        and dcp.diagnosis_coded_year = i.coded_year
    left join count_factors cf
        on d.patient_id = cf.patient_id
        and dcp.diagnosis_coded_year = cf.coded_year
)

select * from score_components
