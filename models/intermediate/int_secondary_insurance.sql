{{
    config(
        tags=['mdm', 'insurance', 'canonical']
    )
}}

/*
  int_secondary_insurance — Canonical Secondary Insurance per Patient

  Mirrors int_primary_insurance but resolves the SECONDARY insurance slot.

  Priority waterfall (matches vw_operating_review_appointments secondary logic):
    1. Latest completed appointment's secondary insurance
       (claim CLAIMSECONDARYPATIENTINSID → eligibility ALTPATIENTINSURANCEID → appointment SECONDARYPATIENTINSURANCEID)
    2. Seq-2 patientinsurance (current secondary on file, joined to insurance_plans dimension)

  Self-Pay is deprioritized at both levels so that a real insurance always wins.

  Key use case: Dual Eligible detection — patients with Medicare primary and Medicaid
  secondary (or vice versa) are identified by comparing int_primary_insurance and
  int_secondary_insurance payor categories.

  Grain: One row per patient_id (only patients with secondary insurance).

  Sources:
    - vw_operating_review_appointments (waterfall-resolved secondary from completed visits)
    - athenahealth.athenaone.patientinsurance (seq=2, not deleted, not cancelled)
    - insurance_plans dimension (standardized classification)
*/

with completed_appt_secondary as (

    select
        cast(patient_id as bigint) as patient_id,
        secondary_insurance_name,
        secondary_insurance_category,
        appointment_date as insurance_as_of_date
    from {{ ref('vw_operating_review_appointments') }}
    where is_completed = true
      and secondary_insurance_name != 'No Insurance Set'
    qualify row_number() over (
        partition by patient_id
        order by appointment_date desc
    ) = 1

),

seq2_insurance as (

    select
        cast(pi.PATIENTID as bigint)    as patient_id,
        pi.PATIENTINSURANCEID           as patient_insurance_id,
        pi.INSURANCEPACKAGEID           as insurance_package_id,
        ip.insurance_package_name,
        ip.insurance_product_type,
        ip.payor_category,
        ip.payor_brand,
        ip.payor_type,
        ip.is_medicare_any,
        ip.is_medigap,
        ip.irc_group,
        ip.government_funded_type,
        pi.POLICYIDNUMBER               as insurance_id_number,
        pi.ISSUEDATE                    as effective_date,
        pi.EXPIRATIONDATE               as expiration_date,
        pi.ELIGIBILITYSTATUS            as eligibility_status,
        pi.ELIGIBILITYLASTCHECKED       as eligibility_last_checked,
        pi.CREATEDDATETIME              as created_at,
        pi.LASTMODIFIEDDATETIME         as last_modified_at
    from {{ source('athenahealth', 'patientinsurance') }} pi
    inner join {{ ref('insurance_plans') }} ip
        on pi.INSURANCEPACKAGEID = ip.insurance_package_id
    where pi.SEQUENCENUMBER = '2'
      and pi.DELETEDDATETIME is null
      and (pi.CANCELLATIONDATE is null or pi.CANCELLATIONDATE > current_date())
    qualify row_number() over (
        partition by pi.PATIENTID
        order by
            case when ip.payor_category = 'Self-Pay' then 1 else 0 end,
            pi.INSURANCEPACKAGEID desc
    ) = 1

),

combined as (

    select
        coalesce(cas.patient_id, s2.patient_id) as patient_id,

        case
            when s2.patient_id is not null then coalesce(s2.insurance_package_name, cas.secondary_insurance_name)
            else cas.secondary_insurance_name
        end as secondary_insurance_name,

        case
            when s2.payor_category is null then
                case
                    when cas.secondary_insurance_category = 'Blue' then 'Commercial'
                    when cas.secondary_insurance_category = 'Medicare' then 'Original Medicare'
                    when cas.secondary_insurance_category = 'Self-Pay' then 'No Insurance Set'
                    else coalesce(cas.secondary_insurance_category, 'No Insurance Set')
                end
            when s2.payor_category in ('Self-Pay', 'No Insurance Set') then 'No Insurance Set'
            when s2.payor_category = 'Blue' then 'Commercial'
            when s2.payor_category = 'Medicare' then 'Original Medicare'
            else s2.payor_category
        end as secondary_payor_category,

        s2.insurance_product_type as secondary_insurance_product_type,
        s2.payor_brand as secondary_payor_brand,
        s2.payor_type as secondary_payor_type,
        coalesce(s2.is_medicare_any, false) as secondary_is_medicare,
        coalesce(s2.is_medigap, false) as secondary_is_medigap,
        s2.irc_group as secondary_irc_group,
        s2.government_funded_type as secondary_government_funded_type,

        case
            when s2.patient_id is not null then 'Patient Insurance (Seq 2)'
            when cas.patient_id is not null then 'Appointment Waterfall'
            else 'None'
        end as secondary_insurance_source,

        case
            when s2.patient_id is not null then cast(s2.last_modified_at as date)
            when cas.patient_id is not null then cas.insurance_as_of_date
            else null
        end as secondary_insurance_as_of_date,

        s2.patient_insurance_id as secondary_patient_insurance_id,
        s2.insurance_package_id as secondary_insurance_package_id,
        s2.insurance_id_number as secondary_insurance_id_number,
        s2.effective_date as secondary_effective_date,
        s2.expiration_date as secondary_expiration_date,
        s2.eligibility_status as secondary_eligibility_status,
        s2.eligibility_last_checked as secondary_eligibility_last_checked,
        s2.created_at as secondary_insurance_created_at,
        s2.last_modified_at as secondary_insurance_modified_at

    from seq2_insurance s2
    full outer join completed_appt_secondary cas
        on s2.patient_id = cas.patient_id

)

select * from combined
