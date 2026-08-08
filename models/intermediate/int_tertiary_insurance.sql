{{
    config(
        tags=['mdm', 'insurance', 'canonical']
    )
}}

/*
  int_tertiary_insurance — Canonical Tertiary Insurance per Patient

  Resolves tertiary insurance from Athena patientinsurance seq=3.
  No claim or appointment-level waterfall exists for tertiary — this is
  the only source. Currently ~64 patients carry a seq-3 record.

  Grain: One row per patient_id (only patients with tertiary insurance).

  Sources:
    - athenahealth.athenaone.patientinsurance (seq=3, not deleted, not cancelled)
    - insurance_plans dimension (standardized classification)
*/

select
    cast(pi.PATIENTID as bigint)    as patient_id,
    pi.PATIENTINSURANCEID           as tertiary_patient_insurance_id,
    pi.INSURANCEPACKAGEID           as tertiary_insurance_package_id,
    ip.insurance_package_name       as tertiary_insurance_name,
    ip.insurance_product_type       as tertiary_insurance_product_type,
    case
        when ip.payor_category = 'Self-Pay' then 'No Insurance Set'
        else coalesce(ip.payor_category, 'No Insurance Set')
    end                             as tertiary_payor_category,
    ip.payor_brand                  as tertiary_payor_brand,
    ip.payor_type                   as tertiary_payor_type,
    coalesce(ip.is_medicare_any, false) as tertiary_is_medicare,
    coalesce(ip.is_medigap, false)  as tertiary_is_medigap,
    ip.irc_group                    as tertiary_irc_group,
    ip.government_funded_type       as tertiary_government_funded_type,
    pi.POLICYIDNUMBER               as tertiary_insurance_id_number,
    pi.ISSUEDATE                    as tertiary_effective_date,
    pi.EXPIRATIONDATE               as tertiary_expiration_date,
    pi.ELIGIBILITYSTATUS            as tertiary_eligibility_status,
    pi.CREATEDDATETIME              as tertiary_insurance_created_at,
    pi.LASTMODIFIEDDATETIME         as tertiary_insurance_modified_at,
    'Patient Insurance (Seq 3)'     as tertiary_insurance_source

from {{ source('athenahealth', 'patientinsurance') }} pi
inner join {{ ref('insurance_plans') }} ip
    on pi.INSURANCEPACKAGEID = ip.insurance_package_id
where pi.SEQUENCENUMBER = '3'
  and pi.DELETEDDATETIME is null
  and (pi.CANCELLATIONDATE is null or pi.CANCELLATIONDATE > current_date())
qualify row_number() over (
    partition by pi.PATIENTID
    order by
        case when ip.payor_category = 'Self-Pay' then 1 else 0 end,
        pi.INSURANCEPACKAGEID desc
) = 1
