{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        schema='marts_bi_v3',
        alias='mart_hcc_grouped',
        unique_key='mart_hcc_grouped_id',
        on_schema_change='append_new_columns',
        tags=['marts_bi_v3', 'cube', 'BIPlatform', 'v3_synced']
    )
}}

{% set payment_year = var('payment_year', 2026) | int %}
{% set prior_year   = payment_year - 1 %}

/*
  Mart: HCC Assessment at HCC grain (one row per patient x HCC).

  SPINE = closure history (int_raf__combined_sources): closed_2025 UNION present_2026.
  Drives the roster off the CLOSURE truth so VendorNav-silent recaptures/suspects are
  caught. int_navina__hcc_assessment_grouped is LEFT JOINed for VendorNav display
  columns (NULL when navina_silent).

  Closure flags are aggregated in ONE CTE keyed by (patient_id, hcc_code) so the
  display LEFT JOIN cannot interfere with the recapture/suspect computation.

  TWO INDEPENDENT AXES:
    A. CLOSURE (recapture/suspect) — combined_sources status in ('CLOSED','CLOSED-PENDING') (= ACCEPTED u claims CODED u billed in-flight):
         hcc_recapture_status: closed_2025 & closed_2026 -> DONE; closed_2025 & not -> OPEN; else NULL
         hcc_is_suspect: not closed_2025 & not closed_2026 & on 2026 record
    B. ASSESSMENT (disposition) — hcc_suggestion_status from the intermediate,
       rank ACCEPTED > HELD > REJECTED > NOT ADDRESSED (matches prod/origin-main int status_priority).

  DATES:
    first_surfaced_date           = earliest 2026 the HCC was seen. COALESCE(earliest VendorNav dos,
                                    earliest 2026 claim/encounter date_of_service). VendorNav is 100% 2026;
                                    the claim fallback is filtered coded_year=2026 (spine spans 2023-26).
                                    Populated for claims-only (navina_silent) HCCs too.
    first_winning_assessment_date = the "win" date. COALESCE(earliest VendorNav WINNING-status dos
                                    (winning = min status_priority, ACC>HELD>REJ>NOT),
                                    earliest 2026 CLOSED claim date). NULL only for a 2026 suspect
                                    that is surfaced-but-not-yet-captured (no win yet).
    first_won_date                = earliest CLOSURE/capture date (ACCEPTED u claims CODED) — NEW.
    earliest_winning_code         = ICD10 that first captured the HCC — NEW.

  PK mart_hcc_grouped_id = patient_id || '_' || hcc_code. source_updated_at for ServingDB TRIGGERED sync.
*/

with closure as (
    select
        patient_id,
        regexp_replace(hcc_code, '^HCC', '') as hcc_code,
        max(case when coded_year = {{ prior_year }} and status in ('CLOSED', 'CLOSED-PENDING') then 1 else 0 end) as f_closed_2025,
        max(case when coded_year = {{ payment_year }} and status in ('CLOSED', 'CLOSED-PENDING') then 1 else 0 end) as f_closed_2026,
        max(case when coded_year = {{ payment_year }} then 1 else 0 end)                       as f_present_2026,
        min(case when status in ('CLOSED', 'CLOSED-PENDING') then date_of_service end)                as first_won_date
    from {{ ref('int_raf__combined_sources') }}
    group by patient_id, regexp_replace(hcc_code, '^HCC', '')
),

spine as (
    select
        patient_id,
        hcc_code,
        f_closed_2025,
        f_closed_2026,
        f_present_2026,
        first_won_date
    from closure
    where (f_closed_2025 = 1 or f_present_2026 = 1)
      and hcc_code is not null and upper(trim(hcc_code)) <> 'NA' and trim(hcc_code) <> ''
),

closure_winning as (
    select
        patient_id,
        regexp_replace(hcc_code, '^HCC', '') as hcc_code,
        diagnosis_code as earliest_winning_code,
        row_number() over (
            partition by patient_id, regexp_replace(hcc_code, '^HCC', '')
            order by date_of_service asc
        ) as rn
    from {{ ref('int_raf__combined_sources') }}
    where status in ('CLOSED', 'CLOSED-PENDING')
),

grouped as (
    select
        *,
        regexp_replace(hcc_code, '^HCC', '') as hcc_code_norm
    from {{ ref('int_navina__hcc_assessment_grouped') }}
),

navina_removed as (
    select
        cast(mrn_id as int)                  as patient_id,
        regexp_replace(hcc_group, '^HCC', '') as hcc_code,
        max(removing_reason)                 as top_removing_reason
    from {{ source('navina_int', 'int_navina_provider_code_level') }}
    where icd_code is not null
      and hcc_group is not null
      and upper(trim(hcc_group)) <> 'NA'
      and to_remove_from_mrn = 'true'
    group by cast(mrn_id as int), regexp_replace(hcc_group, '^HCC', '')
),

hcc_claim as (
    select
        cb.patient_id,
        regexp_replace(cb.hcc_code, '^HCC', '') as hcc_code,
        max(cc.claim_closed) as claim_closed_2026,
        max(cc.claim_billed) as claim_billed_2026
    from {{ ref('int_raf__combined_sources') }} cb
    join {{ ref('int_claim_closed') }} cc
        on cc.patient_id = cb.patient_id
       and cc.diagnosis_code = regexp_replace(upper(trim(cb.diagnosis_code)), '[.]', '')
       and cc.coded_year = cb.coded_year
    where cb.coded_year = {{ payment_year }}
    group by cb.patient_id, regexp_replace(cb.hcc_code, '^HCC', '')
),

navina_first_dates as (
    select
        patient_id,
        hcc_code_norm,
        min(encounter_date)                                                       as first_surfaced_date,
        min(case when status_priority = winning_priority then encounter_date end) as first_winning_assessment_date
    from (
        select
            patient_id,
            regexp_replace(hcc_code, '^HCC', '')                                  as hcc_code_norm,
            encounter_date,
            case upper(trim(suggestion_status))
                when 'ACCEPTED' then 1
                when 'HELD'     then 2
                when 'REJECTED' then 3
                else                 4
            end                                                                   as status_priority,
            min(
                case upper(trim(suggestion_status))
                    when 'ACCEPTED' then 1
                    when 'HELD'     then 2
                    when 'REJECTED' then 3
                    else                 4
                end
            ) over (partition by patient_id, regexp_replace(hcc_code, '^HCC', '')) as winning_priority
        from {{ ref('vw_hcc_assessment') }}
    )
    group by patient_id, hcc_code_norm
),

claim_dates_2026 as (
    select
        patient_id,
        regexp_replace(hcc_code, '^HCC', '')                                      as hcc_code_norm,
        cast(min(date_of_service) as timestamp)                                   as claim_first_surfaced_2026,
        cast(min(case when status in ('CLOSED', 'CLOSED-PENDING') then date_of_service end) as timestamp) as claim_first_won_2026
    from {{ ref('int_raf__combined_sources') }}
    where coded_year = {{ payment_year }}
    group by patient_id, regexp_replace(hcc_code, '^HCC', '')
),

membership as (
    select patient_id, clinic, primary_care_provider
    from (
        select cast(patient_id as int) as patient_id, clinic, primary_care_provider,
            row_number() over (partition by cast(patient_id as int)
                order by case when clinic is not null and primary_care_provider is not null then 0 else 1 end,
                         case when became_inactive_date is null then 0 else 1 end,
                         last_visit_date desc nulls last, source_updated_at desc nulls last) as rn
        from {{ ref('mart_membership') }}
    ) m where rn = 1
)

select
    concat(cast(s.patient_id as string), '_', s.hcc_code)   as mart_hcc_grouped_id,
    s.patient_id,
    s.hcc_code,
    g.npi_id,
    g.provider_name,
    g.department,
    g.mbi,
    g.insurance_group,
    g.primary_insurance,
    case
        when upper(g.primary_insurance) like 'MEDICARE B-MN%'     then 'Original Medicare'
        when upper(g.primary_insurance) like 'PAYOR_A-MN%'           then 'PAYOR_A'
        when upper(g.primary_insurance) like 'PAYOR_EPSILON%'             then 'Payor Epsilon'
        when upper(g.primary_insurance) like 'PAYOR_BETA%' then 'Payor_Beta'
        when upper(g.primary_insurance) like 'MEDICA%'            then 'Medica'
        when upper(g.primary_insurance) like 'PAYOR_DELTA%'    then 'Payor Delta'
        when upper(g.primary_insurance) like 'PAYOR_C%'            then 'PAYOR_C'
        when upper(g.primary_insurance) like 'UCARE%'             then 'UCare'
        when g.primary_insurance is null                         then null
        else 'Other'
    end                                                     as payer,
    case
        when g.primary_insurance is null then null
        when upper(g.primary_insurance) like 'MEDICARE B-MN%'
          or upper(g.primary_insurance) like 'PAYOR_A-MN%'
          or upper(g.primary_insurance) like 'PAYOR_EPSILON%'
          or upper(g.primary_insurance) like 'PAYOR_BETA%' then 'VBC'
        else 'FFS'
    end                                                     as vbc_ffs,
    g.suggestion_type,
    g.suggestion_source,
    g.eligibility_segment,
    g.market,
    g.plan_type,
    g.hcc_coefficient,
    g.navina_hcc_weight,
    g.hcc_encounter_date,
    coalesce(nfd.first_surfaced_date, cd26.claim_first_surfaced_2026)       as first_surfaced_date,
    coalesce(nfd.first_winning_assessment_date, cd26.claim_first_won_2026)  as first_winning_assessment_date,
    g.icd_code_count,
    g.icd10_codes,
    g.hcc_suggestion_status,
    g.is_assessed_hcc,
    g.is_gap_hcc,
    g.is_accepted_hcc,
    cast(case when g.hcc_suggestion_status = 'ACCEPTED' then 1 else 0 end as int)      as accepted_int,
    cast(case when g.hcc_suggestion_status = 'NOT ADDRESSED' then 1 else 0 end as int) as gap_int,
    cast(case when g.hcc_suggestion_status = 'HELD' then 1 else 0 end as int)          as held_int,
    cast(case when g.hcc_suggestion_status = 'REJECTED' then 1 else 0 end as int)      as dismissed_int,
    cast(coalesce(g.is_assessed_hcc, false) as int)                                    as assessed_int,
    cast(1 as int)                                                                     as one,
    g.documentation_strength,
    g.is_recapture_candidate,
    g.has_encounter_diagnosis,
    g.has_claim_diagnosis,
    g.has_problem_list_entry,
    g.last_synced_at,

    case
        when s.f_closed_2025 = 1 and s.f_closed_2026 = 1 then 'DONE'
        when s.f_closed_2025 = 1 and s.f_closed_2026 = 0 then 'OPEN'
        else null
    end                                                     as hcc_recapture_status,
    (s.f_closed_2025 = 0 and s.f_closed_2026 = 0 and s.f_present_2026 = 1) as hcc_is_suspect,
    (s.f_closed_2025 = 1)                                   as is_recapture_target,
    (s.f_closed_2026 = 1)                                   as is_captured_2026,
    (coalesce(hc.claim_closed_2026, 0) = 1)                 as claim_closed_adjudicated,
    (coalesce(hc.claim_billed_2026, 0) = 1)                 as claim_billed,
    s.first_won_date,
    cw.earliest_winning_code,
    (g.patient_id is null)                                  as navina_silent,
    case
        when g.patient_id is not null then 'in_navina_gold'
        when nr.top_removing_reason is not null then nr.top_removing_reason
        else 'athena_claims_only'
    end                                                     as silent_source,

    cast(case when s.f_closed_2025 = 1 and s.f_closed_2026 = 1 then 1 else 0 end as int)                          as recapture_int,
    cast(case when s.f_closed_2025 = 1 and s.f_closed_2026 = 0 then 1 else 0 end as int)                          as recapture_open_int,
    cast(case when s.f_closed_2025 = 1 then 1 else 0 end as int)                                                  as recapture_candidate_int,
    cast(case when s.f_closed_2025 = 0 and s.f_closed_2026 = 0 and s.f_present_2026 = 1 then 1 else 0 end as int)  as suspect_int,
    cast(case when s.f_closed_2026 = 1 then 1 else 0 end as int)                                                  as captured_int,
    cast(case when s.f_closed_2025 = 0 and s.f_closed_2026 = 1 then 1 else 0 end as int)                          as suspect_done_int,
    cast(case when s.f_closed_2025 = 0
                   and (   (s.f_closed_2026 = 0 and s.f_present_2026 = 1)
                         or s.f_closed_2026 = 1 )
              then 1 else 0 end as int)                                                                            as suspect_candidate_int,
    cast(case when coalesce(hc.claim_closed_2026, 0) = 1 then 1 else 0 end as int)                                as claim_proven_int,
    cast(case when coalesce(hc.claim_billed_2026, 0) = 1 then 1 else 0 end as int)                                as claim_billed_int,
    cast(case when g.patient_id is null then 1 else 0 end as int)                                                 as navina_silent_int,
    cast(case when g.patient_id is null then 1 else 0 end as int)                                                 as system_excluded_int,
    cast(case when g.patient_id is not null then 1 else 0 end as int)                                             as actionable_int,
    cast(case when s.f_closed_2026 = 1 and coalesce(hc.claim_billed_2026, 0) = 0 then 1 else 0 end as int)        as pending_closed_int,

    m.clinic                                                                                                       as clinic,
    m.primary_care_provider                                                                                        as provider,
    g.provider_name                                                                                                as assessing_provider,
    case when s.f_closed_2026 = 1 and g.provider_name is not null and m.primary_care_provider is not null
         then (g.provider_name = m.primary_care_provider) else cast(null as boolean) end                          as assessing_matches_pcp,
    cast(case when (s.f_closed_2026 = 1 and g.provider_name is not null and m.primary_care_provider is not null
                    and g.provider_name = m.primary_care_provider) then 1 else 0 end as int)                       as pcp_match_int,
    cast(case when (s.f_closed_2026 = 1 and g.provider_name is not null and m.primary_care_provider is not null
                    and g.provider_name <> m.primary_care_provider) then 1 else 0 end as int)                      as pcp_differs_int,
    cast(case when (s.f_closed_2026 = 1 and g.provider_name is not null and m.primary_care_provider is not null)
              then 1 else 0 end as int)                                                                            as pcp_compared_int,
    g.hcc_suggestion_status                                                                                        as final_status,
    g.suggestion_type                                                                                              as navina_status,
    cast(case when g.hcc_suggestion_status = 'REJECTED' then 1 else 0 end as int)                                  as rejected_int,
    cast(case when g.hcc_suggestion_status = 'NOT ADDRESSED' then 1 else 0 end as int)                             as not_assessed_int,
    cast(case when coalesce(hc.claim_closed_2026, 0) = 1 then 1 else 0 end as int)                                 as claim_closed,
    cast(case when s.f_closed_2025 = 1 then 1 else 0 end as int)                                                   as recapture,
    cast(case when s.f_closed_2025 = 0
                   and (   (s.f_closed_2026 = 0 and s.f_present_2026 = 1)
                         or s.f_closed_2026 = 1 )
              then 1 else 0 end as int)                                                                            as suspect,

    coalesce(g.last_synced_at, cast('1900-01-01' as timestamp)) as source_updated_at
from spine s
left join grouped         g  on g.patient_id = s.patient_id and g.hcc_code_norm = s.hcc_code
left join navina_removed  nr on nr.patient_id = s.patient_id and nr.hcc_code = s.hcc_code
left join hcc_claim       hc on hc.patient_id = s.patient_id and hc.hcc_code = s.hcc_code
left join closure_winning cw on cw.patient_id = s.patient_id and cw.hcc_code = s.hcc_code and cw.rn = 1
left join navina_first_dates nfd on nfd.patient_id = s.patient_id and nfd.hcc_code_norm = s.hcc_code
left join claim_dates_2026   cd26 on cd26.patient_id = s.patient_id and cd26.hcc_code_norm = s.hcc_code
left join membership          m  on m.patient_id = s.patient_id
