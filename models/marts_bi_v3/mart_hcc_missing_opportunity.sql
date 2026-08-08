{{
    config(
        materialized='table',
        schema='marts_bi_v3',
        alias='mart_hcc_missing_opportunity',
        tags=['marts_bi_v3', 'BIPlatform', 'v3_synced']
    )
}}

with shadow as (

    select
        cast(patient_id as string) as patient_id,
        comparison_class,
        prior_year_closed_at,
        current_year_closed_at
    from {{ ref('mart_suspect_recapture') }}
    where comparison_class in ('org_only_recapture', 'org_suspect_navina_silent')

),

cohorts as (

    select
        patient_id,
        max(case when comparison_class = 'org_only_recapture'        then 1 else 0 end) as is_recapture,
        max(case when comparison_class = 'org_suspect_navina_silent' then 1 else 0 end) as is_suspect,
        max(coalesce(current_year_closed_at, prior_year_closed_at)) as max_closed_at
    from shadow
    group by patient_id

),

roster as (

    select distinct cast(patient_mrn as string) as patient_mrn
    from {{ ref('gold_navina_patient_roster') }}
    where patient_mrn is not null
      and trim(cast(patient_mrn as string)) <> ''

),

missing as (

    select
        c.patient_id,
        c.is_recapture,
        c.is_suspect,
        c.max_closed_at
    from cohorts c
    left join roster r
        on c.patient_id = r.patient_mrn
    where r.patient_mrn is null

),

appt_flags as (

    select
        cast(patient_id as string) as patient_id,
        max(case when is_future_appointment = true then 1 else 0 end) as has_future_appt,
        max(case when is_completed = true
                  and year(appointment_date) = 2026 then 1 else 0 end) as has_completed_2026,
        max(cast(appointment_date as timestamp)) as max_appt_date
    from {{ ref('mart_appointments') }}
    group by cast(patient_id as string)

)

select
    cast(m.patient_id as string)                    as mart_hcc_missing_opportunity_id,
    cast(m.patient_id as string)                    as patient_id,
    cast(m.is_recapture as int)                     as is_recapture,
    cast(m.is_suspect as int)                        as is_suspect,
    cast(coalesce(a.has_future_appt, 0) as int)     as has_future_appt,
    cast(coalesce(a.has_completed_2026, 0) as int)  as has_completed_2026,
    cast(case when coalesce(a.has_future_appt, 0) = 0
                and coalesce(a.has_completed_2026, 0) = 0
              then 1 else 0 end as int)             as no_2026_visit,
    cast(1 as int)                                  as missing_any,
    cast(case when m.is_recapture = 1
                and coalesce(a.has_future_appt, 0) = 0
                and coalesce(a.has_completed_2026, 0) = 0
              then 1 else 0 end as int)             as recapture_needs_sched,
    cast(case when m.is_suspect = 1
                and coalesce(a.has_future_appt, 0) = 0
                and coalesce(a.has_completed_2026, 0) = 0
              then 1 else 0 end as int)             as suspect_needs_sched,
    coalesce(
        greatest(m.max_closed_at, a.max_appt_date),
        m.max_closed_at,
        a.max_appt_date,
        cast('1900-01-01' as timestamp)
    )                                               as source_updated_at
from missing m
left join appt_flags a
    on m.patient_id = a.patient_id
