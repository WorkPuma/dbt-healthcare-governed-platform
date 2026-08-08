{{
  config(
    schema='raf_intermediate',
    tags=['raf', 'intermediate', 'empi']
  )
}}

/*
  Intermediate: RAF Demographic Spine (EMPI-keyed)

  One demographic row per scoreable member, keyed on the stable EMPI entity:
    entity_id = Athena patient_id (matched) OR identity_id (roster-only ghost).

  Two legs, unioned:
    1. Athena patients  -> int_patient_supplement (full EHR demographics +
       provider/department/enterprise enrichment). is_ghost = false.
    2. Roster-only ghosts -> latest demographics carried on attribution_history
       (payor-file first/last name, DOB, gender). No Athena record, so all EHR
       enrichment columns are NULL and is_ghost = true. Gender maps to sex_code
       (M/F/U); unknown/missing gender resolves to 'U' (demographic factor 0).

  This is the single demographic input for the RAF score chain so that
  demographic-only scores can be produced for ghosts WITHOUT joining any
  Athena/Salesforce/appointment table.
*/

with athena as (
    select
        cast(patient_id as string)                          as entity_id,
        cast(null as string)                                as identity_id,
        cast(patient_id as bigint)                          as patient_id,
        cast(false as boolean)                              as is_ghost,
        cast(first_name as {{ dbt.type_string() }})         as first_name,
        cast(last_name as {{ dbt.type_string() }})          as last_name,
        cast(date_of_birth as date)                         as date_of_birth,
        cast(sex as {{ dbt.type_string() }})                as sex,
        cast(sex_code as {{ dbt.type_string() }})           as sex_code,
        cast(primary_provider_id as bigint)                 as primary_provider_id,
        cast(provider_last_name as {{ dbt.type_string() }}) as provider_last_name,
        cast(provider_npi as {{ dbt.type_string() }})       as provider_npi,
        cast(department_id as bigint)                        as department_id,
        cast(department_name as {{ dbt.type_string() }})    as department_name,
        cast(enterprise_id as bigint)                       as enterprise_id
    from {{ ref('int_patient_supplement') }}
),

-- Latest demographics per ghost identity (most recent roster appearance).
ghost_demo as (
    select
        identity_id,
        patient_first_name,
        patient_last_name,
        patient_date_of_birth,
        patient_gender
    from {{ ref('attribution_history') }}
    where is_ghost = true
      and identity_id is not null
    -- Deterministic latest-row pick: as_of_month / source_updated_at are the
    -- intent, then DOB + name + gender as stable tiebreakers so the chosen
    -- demographic row is reproducible run-over-run even when the leading
    -- timestamps tie (otherwise the score could flip between equally-recent rows).
    qualify row_number() over (
        partition by identity_id
        order by
            as_of_month desc nulls last,
            source_updated_at desc nulls last,
            patient_date_of_birth desc nulls last,
            patient_last_name desc nulls last,
            patient_first_name desc nulls last,
            patient_gender desc nulls last
    ) = 1
),

ghost as (
    select
        g.identity_id                                       as entity_id,
        g.identity_id                                       as identity_id,
        cast(null as bigint)                                as patient_id,
        cast(true as boolean)                               as is_ghost,
        cast(g.patient_first_name as {{ dbt.type_string() }}) as first_name,
        cast(g.patient_last_name as {{ dbt.type_string() }})  as last_name,
        try_cast(g.patient_date_of_birth as date)           as date_of_birth,
        upper(trim(g.patient_gender))                       as sex,
        case
            when upper(trim(g.patient_gender)) in ('M', 'MALE', '1')   then 'M'
            when upper(trim(g.patient_gender)) in ('F', 'FEMALE', '2') then 'F'
            else 'U'
        end                                                 as sex_code,
        cast(null as bigint)                                as primary_provider_id,
        cast(null as {{ dbt.type_string() }})               as provider_last_name,
        cast(null as {{ dbt.type_string() }})               as provider_npi,
        cast(null as bigint)                                as department_id,
        cast(null as {{ dbt.type_string() }})               as department_name,
        cast(null as bigint)                                as enterprise_id
    from ghost_demo g
)

select * from athena
union all
select * from ghost
