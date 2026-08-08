{{
    config(
        tags=['mdm', 'insurance', 'canonical']
    )
}}

/*
  int_primary_insurance — Canonical Primary Insurance per Patient

  PRIMARY ANCHOR for Active Primary Insurance across the data model.

  Priority waterfall (matches vw_operating_review_appointments logic):
    1. Latest completed appointment's insurance (claim billed → eligibility → appointment)
       The appointment-level waterfall resolves insurance from the most reliable source:
       claim billed > eligibility verified > appointment set. We take the most recent
       completed appointment's resolved insurance.
    2. Seq-1 patientinsurance (current insurance on file, joined to insurance_plans dimension)
       For patients without completed appointments, or when the completed appointment
       has no insurance resolved.

  Self-Pay is deprioritized at both levels so that a real insurance always wins.

  For HISTORICAL (appointment-level) insurance at a specific point in time, use the
  waterfall in vw_operating_review_appointments directly. This model gives the CURRENT
  best-known primary insurance per patient.

  Classification comes from the insurance_plans dimension (MDM-governed):
    payor_category: Original Medicare, Medicare Advantage, Medicare Supplement,
                    Commercial, Medicaid, Self-Pay
    payor_brand: PAYOR_A, PAYOR_B, Payor Epsilon, Payor Delta, PAYOR_C, Medicare FFS, etc.

  Grain: One row per patient_id.

  Sources:
    - vw_operating_review_appointments (waterfall-resolved insurance from completed visits)
    - athenahealth.athenaone.patientinsurance (seq=1, not deleted, not cancelled)
    - insurance_plans dimension (standardized classification)
*/

-- Priority 1: Latest completed appointment's insurance (waterfall-resolved)
-- Uses vw_operating_review_appointments (source-only refs) to avoid circular dependency
with completed_appt_insurance as (

    select
        cast(patient_id as bigint) as patient_id,
        primary_insurance_name,
        primary_insurance_category,
        primary_insurance_product_type,
        primary_insurance_source,
        appointment_date as insurance_as_of_date
    from {{ ref('vw_operating_review_appointments') }}
    where is_completed = true
      and primary_insurance_name != 'No Insurance Set'
    qualify row_number() over (
        partition by patient_id
        order by appointment_date desc
    ) = 1

),

-- Priority 2: Seq-1 patientinsurance → insurance_plans dimension
seq1_insurance as (

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
        pi.SHORTNAME                    as policy_holder,
        pi.ISSUEDATE                    as effective_date,
        pi.EXPIRATIONDATE               as expiration_date,
        pi.ELIGIBILITYSTATUS            as eligibility_status,
        pi.ELIGIBILITYLASTCHECKED       as eligibility_last_checked,
        pi.CREATEDDATETIME              as created_at,
        pi.LASTMODIFIEDDATETIME         as last_modified_at
    from {{ source('athenahealth', 'patientinsurance') }} pi
    inner join {{ ref('insurance_plans') }} ip
        on pi.INSURANCEPACKAGEID = ip.insurance_package_id
    where pi.SEQUENCENUMBER = '1'
      and pi.DELETEDDATETIME is null
      and (pi.CANCELLATIONDATE is null or pi.CANCELLATIONDATE > current_date())
    qualify row_number() over (
        partition by pi.PATIENTID
        order by
            case when ip.payor_category = 'Self-Pay' then 1 else 0 end,
            pi.INSURANCEPACKAGEID desc
    ) = 1

),

-- Combine: completed appointment insurance wins, seq-1 is fallback
combined as (

    select
        coalesce(cai.patient_id, s1.patient_id) as patient_id,

        -- Insurance name: seq-1 is current active insurance, appointment waterfall is historical
        case
            when s1.patient_id is not null then coalesce(s1.insurance_package_name, cai.primary_insurance_name)
            else 'No Insurance Set'
        end as primary_insurance_name,

        -- Classification: only from insurance_plans dimension (seq-1 joined)
        -- Self-Pay and no-insurance patients both get 'No Insurance Set'
        case
            when s1.payor_category is null then 'No Insurance Set'
            when s1.payor_category = 'Self-Pay' then 'No Insurance Set'
            else s1.payor_category
        end as primary_payor_category,

        -- Product type: from insurance_plans dimension
        s1.insurance_product_type as primary_insurance_product_type,

        -- Brand & type: only available from seq-1 (insurance_plans dimension)
        s1.payor_brand as primary_payor_brand,
        s1.payor_type as primary_payor_type,

        -- Medicare flags: seq-1 is authoritative (insurance_plans dimension)
        coalesce(s1.is_medicare_any, false) as primary_is_medicare,
        coalesce(s1.is_medigap, false) as primary_is_medigap,
        s1.irc_group as primary_irc_group,
        s1.government_funded_type as primary_government_funded_type,

        -- Source tracking
        case
            when s1.patient_id is not null then 'Patient Insurance (Seq 1)'
            when cai.patient_id is not null then cai.primary_insurance_source
            else 'None'
        end as primary_insurance_source,

        -- As-of date
        case
            when s1.patient_id is not null then cast(s1.last_modified_at as date)
            when cai.patient_id is not null then cai.insurance_as_of_date
            else null
        end as primary_insurance_as_of_date,

        -- Seq-1 details (always available for enrichment)
        s1.patient_insurance_id,
        s1.insurance_package_id,
        s1.insurance_id_number,
        s1.policy_holder,
        s1.effective_date as primary_effective_date,
        s1.expiration_date as primary_expiration_date,
        s1.eligibility_status as primary_eligibility_status,
        s1.eligibility_last_checked as primary_eligibility_last_checked,
        s1.created_at as primary_insurance_created_at,
        s1.last_modified_at as primary_insurance_modified_at

    from seq1_insurance s1
    full outer join completed_appt_insurance cai
        on s1.patient_id = cai.patient_id

)

select
    patient_id,
    primary_insurance_name,
    primary_insurance_product_type,
    primary_payor_category,
    primary_payor_brand,
    primary_payor_type,
    primary_is_medicare,
    primary_is_medigap,
    primary_irc_group,
    primary_government_funded_type,
    primary_insurance_source,
    primary_insurance_as_of_date,
    patient_insurance_id,
    insurance_package_id,
    insurance_id_number,
    policy_holder,
    primary_effective_date,
    primary_expiration_date,
    primary_eligibility_status,
    primary_eligibility_last_checked,
    case
        when primary_payor_category = 'No Insurance Set' then 'No Insurance'
        when primary_eligibility_status = 'Eligible' then 'Active'
        when primary_eligibility_status is null then 'Unknown'
        else primary_eligibility_status
    end as primary_insurance_status,
    primary_insurance_created_at,
    primary_insurance_modified_at
from combined
