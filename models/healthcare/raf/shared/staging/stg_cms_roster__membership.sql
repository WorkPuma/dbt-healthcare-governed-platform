{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'cms_roster', 'placeholder']
  )
}}

/*
  Staging: CMS Roster Membership / Patient Census

  CMS Roster patient census and attribution data. Provides fallback
  eligibility segment information when CMS MMR is unavailable.

  Decision D6: CMS Roster is the fallback eligibility source.
  When CMS MMR becomes available (Phase 4), it becomes primary.

  Note: Source location TBD -- this model currently references the frozen
  enrollment seed (ref_raf__patient_enrollment_segment) as the best available
  proxy for CMS Roster membership data. Canonical CMS Roster/CMS feed tracked in
  JIRA TIC-7529.

  Source (2026-06 raf_staging eradication): dbt seed
  ref_raf__patient_enrollment_segment (frozen snapshot, proxy)
*/

with source as (
    select * from {{ ref('ref_raf__patient_enrollment_segment') }}
),

renamed as (
    select
        cast(patient_id as bigint)                         as patient_id,
        upper(trim(enrollment_code))                       as enrollment_type,
        -- Map to CMS standard segments
        case
            when upper(trim(enrollment_code)) = 'CNA' then 'Community Non-Dual Aged'
            when upper(trim(enrollment_code)) = 'NE' then 'New Enrollee'
            when upper(trim(enrollment_code)) = 'CND' then 'Community Non-Dual Disabled'
            when upper(trim(enrollment_code)) = 'CFA' then 'Community Full Dual Aged'
            when upper(trim(enrollment_code)) = 'CFD' then 'Community Full Dual Disabled'
            when upper(trim(enrollment_code)) = 'CPA' then 'Community Partial Dual Aged'
            when upper(trim(enrollment_code)) = 'CPD' then 'Community Partial Dual Disabled'
            when upper(trim(enrollment_code)) = 'INS' then 'Institutional'
            when upper(trim(enrollment_code)) = 'SNPNE' then 'SNP New Enrollee'
            else 'Unknown'
        end                                               as segment_description,
        -- Flag dual-eligible
        case
            when upper(trim(enrollment_code)) in ('CFA', 'CFD', 'CPA', 'CPD')
                then true
            else false
        end                                               as is_dual_eligible,
        -- Flag new enrollee
        case
            when upper(trim(enrollment_code)) in ('NE', 'SNPNE')
                then true
            else false
        end                                               as is_new_enrollee,
        'CMS_ROSTER_PROXY'                                     as data_source
    from source
)

select distinct * from renamed
