{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='survey_id',
        matched_condition="coalesce(t.source_updated_at, timestamp '1900-01-01') < s.source_updated_at",
        on_schema_change='append_new_columns',
        schema='healthcare',
        alias='patient_experience',
        tags=['fact', 'cube', 'BIPlatform', 'nps', 'survey']
    )
}}

/*
  fct_provider_nps — Provider NPS Survey Fact

  Wraps the existing vw_provider_nps_salesforce model with conformed dimension keys.
  Includes AI-powered sentiment analysis of patient survey comments.

  Grain: One row per survey response (appointment_id).
  Sources: vw_provider_nps_salesforce, patients, patient_identity
*/

select
    -- Survey Identity
    nps.ID as survey_id,
    nps.APPOINTMENT_ID as appointment_id,
    nps.PATIENT_ID as patient_id,

    -- Patient Identity Bridge
    dp.golden_id,
    dpi.salesforce_id,
    dpi.enterprise_id,

    -- Time
    nps.START_DATE as survey_date,
    year(nps.START_DATE) as survey_year,
    month(nps.START_DATE) as survey_month,

    -- Provider & Location
    nps.PHYSICIAN_NAME as provider_name,
    nps.LOCATION_NAME as clinic_name,
    nps.APPOINTMENT_TYPE as appointment_type,

    -- NPS Scores (1-5 scale)
    nps.LIKELY_TO_RECOMMEND_CLINIC as recommend_score,
    nps.CLINIC_SATISFACTION as clinic_satisfaction_score,
    nps.CLINICAL_FOLLOW_UP_SATISFACTION as followup_satisfaction_score,
    nps.PROVIDER_SATISFACTION as provider_satisfaction_score,

    -- Derived NPS Category (based on recommend_score 1-5 mapped to 0-10 scale)
    case
        when nps.LIKELY_TO_RECOMMEND_CLINIC >= 5 then 'Promoter'
        when nps.LIKELY_TO_RECOMMEND_CLINIC >= 4 then 'Passive'
        else 'Detractor'
    end as nps_category,

    -- Average satisfaction
    round(
        (coalesce(nps.LIKELY_TO_RECOMMEND_CLINIC, 0) +
         coalesce(nps.CLINIC_SATISFACTION, 0) +
         coalesce(nps.CLINICAL_FOLLOW_UP_SATISFACTION, 0) +
         coalesce(nps.PROVIDER_SATISFACTION, 0)) / 4.0,
        2
    ) as avg_satisfaction_score,

    -- Survey Comments & AI Sentiment
    nps.SURVEY_COMMENTS as survey_comments,
    nps.SENTIMENT_LABEL as sentiment,

    -- CDF watermark — propagated from upstream NPS + patient identity sources
    greatest(
        coalesce(nps.source_updated_at, timestamp '1900-01-01'),
        coalesce(dp.last_updated_at, timestamp '1900-01-01')
    ) as source_updated_at

from {{ ref('vw_provider_nps_salesforce') }} nps
left join {{ ref('patients') }} dp
    on nps.PATIENT_ID = dp.patient_id
left join {{ ref('patient_identity') }} dpi
    on dp.golden_id = dpi.golden_id
