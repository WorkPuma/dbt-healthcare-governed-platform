{{
  config(
    schema='raf_intermediate',
    tags=['raf', 'intermediate', 'legacy']
  )
}}

/*
  Intermediate: Patient Supplement

  Replaces: TWICE.INTERTABLES.PATIENT_SUPPLEMENT
  Sources: athena patient + provider + customdemographics + department

  Enriched patient demographic view with provider, department, and
  custom demographics joined. Core input for demographic RAF scoring.
*/

with patient as (
    select * from {{ source('athena_raf', 'patient') }}
),

provider as (
    select * from {{ source('athena_raf', 'provider') }}
),

custom_demo as (
    select * from {{ source('athena_raf', 'customdemographics') }}
),

department as (
    select * from {{ source('athena_raf', 'department') }}
),

-- Databricks customdemographics is EAV — pivot to get custom fields
custom_demo_pivoted as (
    select
        CONTEXTID as patient_context_id,
        max(case when CUSTOMFIELDNAME = 'CustomField1' then CUSTOMFIELDVALUE end) as custom_field_1,
        max(case when CUSTOMFIELDNAME = 'CustomField2' then CUSTOMFIELDVALUE end) as custom_field_2
    from custom_demo
    group by CONTEXTID
),

supplement as (
    select
        cast(p.PATIENTID as int)                          as patient_id,
        p.FIRSTNAME                                       as first_name,
        p.LASTNAME                                        as last_name,
        p.DOB                                             as date_of_birth,
        -- FIX B19: Use actual patient sex, NOT hardcoded 'F'
        upper(trim(p.SEX))                                as sex,
        case
            when upper(trim(p.SEX)) = 'M' then 'M'
            when upper(trim(p.SEX)) = 'F' then 'F'
            else 'U'
        end                                               as sex_code,
        p.PATIENTSTATUS                                   as patient_status,
        p.ENTERPRISEID                                    as enterprise_id,
        p.PATIENTSSN                                      as ssn_last_four,
        -- Provider info (primary)
        prov.PROVIDERID                                   as primary_provider_id,
        prov.PROVIDERFIRSTNAME                            as provider_first_name,
        prov.PROVIDERLASTNAME                             as provider_last_name,
        prov.PROVIDERNPINUMBER                            as provider_npi,
        prov.PROVIDERTYPE                                 as provider_type,
        -- Department
        dept.DEPARTMENTID                                 as department_id,
        dept.DEPARTMENTNAME                               as department_name,
        -- Custom demographics (pivoted from EAV)
        cdp.custom_field_1,
        cdp.custom_field_2
    from patient p
    left join provider prov
        on p.PRIMARYPROVIDERID = prov.PROVIDERID
    left join department dept
        on p.CURRENTDEPARTMENTID = dept.DEPARTMENTID
    left join custom_demo_pivoted cdp
        on p.CONTEXTID = cdp.patient_context_id
    where p.PATIENTID is not null
)

select * from supplement
