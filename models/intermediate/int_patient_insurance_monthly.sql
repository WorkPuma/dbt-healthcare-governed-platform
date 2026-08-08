{{
    config(
        tags=['mdm', 'insurance', 'canonical', 'raf']
    )
}}

/*
  int_patient_insurance_monthly — Patient Insurance by Month

  Grain: patient_id × status_month

  Derives monthly insurance from the appointment-level waterfall in
  vw_operating_review_appointments (claim → eligibility → appointment),
  then joins through to the insurance_plans MDM dimension for the
  canonical classification (payor_category, payor_brand, payor_type).

  The appointment waterfall resolves insurance via:
    1. Claim billed (most accurate)
    2. Eligibility verified
    3. Appointment record

  For months without appointments, the most recent appointment's
  insurance is forward-filled. For patients with no appointment history,
  int_primary_insurance (seq-1) provides the fallback.

  Spine: stg_raf__patient_status_monthly (patient × month). Additional
  consumers (membership tracking, payer mix) can ref this model directly.

  Consumers:
    - dim_raf__attribution (monthly RAF member dimension)
    - Patient census, membership trending, payer mix reporting
*/

with patient_month_spine as (
    select
        patient_id,
        status_month
    from {{ ref('stg_raf__patient_status_monthly') }}
),

completed_with_insurance as (
    select
        cast(a.patient_id as int)                          as patient_id,
        a.appointment_date,
        last_day(a.appointment_date)                       as appointment_month_end,
        a.primary_insurance_name,
        a.primary_insurance_product_type                   as appt_insurance_product_type,
        a.primary_insurance_source                         as waterfall_source,
        a.primary_patient_insurance_id,
        a.secondary_insurance_name,
        a.secondary_insurance_category,
        a.secondary_patient_insurance_id,
        ip.payor_category,
        ip.payor_brand,
        ip.payor_type,
        ip.insurance_product_type                          as mdm_insurance_product_type,
        ip.is_medicare_any,
        ip.is_medigap,
        ip.irc_group,
        ip.government_funded_type
    from {{ ref('vw_operating_review_appointments') }} a
    left join {{ source('athenahealth', 'patientinsurance') }} pi
        on a.primary_patient_insurance_id = pi.PATIENTINSURANCEID
    left join {{ ref('insurance_plans') }} ip
        on pi.INSURANCEPACKAGEID = ip.insurance_package_id
    where a.is_completed = true
      and a.primary_insurance_name != 'No Insurance Set'
),

latest_per_month as (
    select *
    from completed_with_insurance
    qualify row_number() over (
        partition by patient_id, appointment_month_end
        order by appointment_date desc
    ) = 1
),

spine_with_appt_insurance as (
    select
        pm.patient_id,
        pm.status_month,
        lpm.appointment_date,
        lpm.primary_insurance_name,
        lpm.appt_insurance_product_type,
        lpm.waterfall_source,
        lpm.primary_patient_insurance_id,
        lpm.payor_category,
        lpm.payor_brand,
        lpm.payor_type,
        lpm.mdm_insurance_product_type,
        lpm.is_medicare_any,
        lpm.is_medigap,
        lpm.irc_group,
        lpm.government_funded_type,
        lpm.secondary_insurance_name,
        lpm.secondary_insurance_category,
        lpm.secondary_patient_insurance_id
    from patient_month_spine pm
    left join latest_per_month lpm
        on pm.patient_id = lpm.patient_id
        and pm.status_month = lpm.appointment_month_end
),

forward_filled as (
    select
        patient_id,
        status_month,

        last_value(appointment_date, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as insurance_as_of_date,

        last_value(primary_insurance_name, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as primary_insurance_name,

        last_value(waterfall_source, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as waterfall_source,

        last_value(primary_patient_insurance_id, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as primary_patient_insurance_id,

        last_value(payor_category, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as payor_category,

        last_value(payor_brand, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as payor_brand,

        last_value(payor_type, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as payor_type,

        last_value(coalesce(mdm_insurance_product_type, appt_insurance_product_type), true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as insurance_product_type,

        last_value(is_medicare_any, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as is_medicare,

        last_value(is_medigap, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as is_medigap,

        last_value(irc_group, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as irc_group,

        last_value(government_funded_type, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as government_funded_type,

        last_value(secondary_insurance_name, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as secondary_insurance_name,

        last_value(secondary_insurance_category, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as secondary_insurance_category,

        last_value(secondary_patient_insurance_id, true) over (
            partition by patient_id order by status_month
            rows between unbounded preceding and current row
        ) as secondary_patient_insurance_id,

        case when appointment_date is not null then true else false end as has_appointment_this_month

    from spine_with_appt_insurance
),

seq1_fallback as (
    select * from {{ ref('int_primary_insurance') }}
),

final as (
    select
        ff.patient_id,
        ff.status_month,

        coalesce(ff.primary_insurance_name, fb.primary_insurance_name, 'No Insurance Set')
            as insurance_name,
        coalesce(ff.payor_category, fb.primary_payor_category, 'Unknown')
            as payor_category,
        coalesce(ff.payor_brand, fb.primary_payor_brand)
            as payor_brand,
        coalesce(ff.payor_type, fb.primary_payor_type)
            as payor_type,
        coalesce(ff.insurance_product_type, fb.primary_insurance_product_type)
            as insurance_product_type,
        coalesce(ff.is_medicare, fb.primary_is_medicare, false)
            as is_medicare,
        coalesce(ff.is_medigap, fb.primary_is_medigap, false)
            as is_medigap,
        coalesce(ff.irc_group, fb.primary_irc_group)
            as irc_group,
        coalesce(ff.government_funded_type, fb.primary_government_funded_type)
            as government_funded_type,

        ff.secondary_insurance_name,
        ff.secondary_insurance_category,

        case
            when ff.primary_insurance_name is not null and ff.has_appointment_this_month
                then 'Appointment (Same Month)'
            when ff.primary_insurance_name is not null
                then 'Appointment (Forward-Fill)'
            when fb.primary_insurance_name is not null
                then 'Seq-1 Fallback'
            else 'None'
        end as insurance_resolution_source,

        ff.insurance_as_of_date,
        ff.waterfall_source,
        coalesce(ff.primary_patient_insurance_id, fb.patient_insurance_id)
            as primary_patient_insurance_id

    from forward_filled ff
    left join seq1_fallback fb
        on ff.patient_id = fb.patient_id
        and ff.primary_insurance_name is null
)

select * from final
