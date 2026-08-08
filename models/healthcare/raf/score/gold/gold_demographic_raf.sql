{{
  config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['patient_id', 'payment_year'],
        matched_condition='t.source_updated_at < s.source_updated_at',
        on_schema_change='append_new_columns',
        schema='healthcare',
    tags=['raf', 'gold', 'legacy', 'backwards_compat']
  )
}}

/*
  Legacy Gold: Demographic RAF

  Replaces: TWICE.RAF.DEMOGRAPHIC_RAF

  FIXES:
    B19 - Uses actual patient sex (not hardcoded 'F')
    D16 - Uses full 9-segment eligibility (not CNA/NE only)

  Pure demographic factor per patient -- no disease HCCs.
  Every attributed patient gets a demographic RAF score based
  on their age, sex, and eligibility segment.

  Uses int_raf__demographic_factors (parameterized, correct sex/eligibility)
  instead of the broken Snowflake CALCULATE_DEMOGRAPHIC_RISK UDF.
*/

with demographics as (
    select * from {{ ref('int_raf__demographic_factors') }}
),

patient_supplement as (
    select * from {{ ref('int_patient_supplement') }}
),

eligibility as (
    select * from {{ ref('int_raf__eligibility_segment') }}
),

patient_timestamps as (
    select patient_id, last_updated_at
    from {{ ref('patients') }}
),

attribution as (
    -- dim_raf__attribution is at MONTHLY grain — one row per
    -- (patient_id, status_month, payment_year) where is_active reflects
    -- attribution status that calendar month. A patient who churns mid-year
    -- has both is_active=true and is_active=false rows.
    --
    -- For year-level demographic RAF, the canonical convention is "use the
    -- LATEST observed month's attribution status" (point-in-time per year).
    -- We collapse to one row per (patient_id, payment_year) by ranking on
    -- status_month DESC and keeping rank 1.
    --
    -- DO NOT use SELECT DISTINCT — it would silently keep both is_active
    -- rows and fan out the downstream MERGE
    -- (DELTA_MULTIPLE_SOURCE_ROW_MATCHING_TARGET_ROW_IN_MERGE).
    select
        patient_id,
        payment_year,
        is_active
    from {{ ref('dim_raf__attribution') }}
    {% if is_incremental() %}
    where patient_id in (
        select patient_id from patient_timestamps
        where last_updated_at >= (
            select dateadd(hour, -24, coalesce(max(source_updated_at), timestamp '1900-01-01'))
            from {{ this }}
        )
    )
    {% endif %}
    qualify row_number() over (
        partition by patient_id, payment_year
        order by year_month desc, month_number desc
    ) = 1
),

demographic_raf as (
    select
        a.patient_id,
        a.payment_year,
        a.is_active,
        -- Demographics
        ps.first_name,
        ps.last_name,
        ps.date_of_birth,
        ps.sex_code,
        -- Age calculation
        d.age,
        d.age_band,
        -- Eligibility (FIX D16: full 9-segment)
        coalesce(e.eligibility_segment, 'CNA')            as eligibility_segment,
        coalesce(e.segment_name, 'Community NonDual Aged') as segment_name,
        coalesce(e.is_new_enrollee, false)                 as is_new_enrollee,
        coalesce(e.is_dual_eligible, false)                as is_dual_eligible,
        -- Demographic factor coefficient key
        d.coefficient_key,
        -- Demographic RAF score (FIX B19: actual patient sex)
        coalesce(d.demographic_factor, 0)                 as demographic_raf_score,
        -- Provider
        ps.primary_provider_id,
        ps.provider_last_name                              as provider_name,
        ps.provider_npi,
        -- CDF change tracking
        GREATEST(
            COALESCE(pt.last_updated_at, TIMESTAMP '1900-01-01'),
            COALESCE(e.last_updated_at, TIMESTAMP '1900-01-01')
        ) as source_updated_at
    from attribution a
    inner join patient_supplement ps
        on a.patient_id = ps.patient_id
    left join demographics d
        on a.patient_id = d.patient_id
    left join eligibility e
        on a.patient_id = e.patient_id
    left join patient_timestamps pt
        on a.patient_id = pt.patient_id
)

select * from demographic_raf
