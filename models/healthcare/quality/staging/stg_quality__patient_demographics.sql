{{
    config(
        materialized='view',
        tags=['quality', 'hedis', 'staging', 'dev-4296']
    )
}}

-- staging — DEV-4296 · stg_quality__patient_demographics (ported as-is from PAYOR_A-quality-v3-port)
-- 1:1 over athenahealth.patient: the demographic columns the PAYOR_A contract_output needs
-- (name/dob/gender/race/language/address/city/state/zip) + attributed_provider_id (step D NPI
-- fallback) + is_deceased/deceased_date (deceased flag lives here,
-- no separate DQ source). schema=healthcare via folder config.
-- SOFT-DELETE HYGIENE (PR #346 #1): drop athena-deleted (deleteddatetime) + test patients so the
-- roster denominator is not inflated. deceased is NOT dropped here (handled downstream via Active gating).
select
    p.patientid                                            as patient_id,
    p.firstname                                            as first_name,
    p.lastname                                             as last_name,
    p.dob                                                  as date_of_birth,
    p.sex                                                  as gender,
    p.race                                                 as race_primary,
    p.language                                             as preferred_language,
    p.address                                              as address_line_1,
    p.address2                                             as address_line_2,
    p.city                                                 as city,
    p.state                                                as state,
    p.zip                                                  as zip_code,
    p.primaryproviderid                                    as attributed_provider_id,
    p.contextid                                            as primary_department_id,
    p.enterpriseid                                         as enterprise_id,
    p.patientstatus                                        as patient_status,
    p.deceaseddate                                         as deceased_date,
    case when p.deceaseddate is not null then true else false end as is_deceased
from {{ source('athenahealth', 'patient') }} p
where p.deleteddatetime is null
  and coalesce(p.testpatientyn, 'N') <> 'Y'
