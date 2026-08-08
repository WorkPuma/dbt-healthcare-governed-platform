{{
  config(
    schema='raf_intermediate',
    tags=['raf', 'intermediate', 'legacy']
  )
}}

/*
  Intermediate: Claim Info

  Replaces: TWICE.INTERTABLES.CLAIM_INFO
  Sources: athena claim + claimnote + claimaudit

  Note: claimstatus is intentionally DROPPED (B3) -- it was a dead
  join in the original Snowflake view where columns were never selected.
*/

with claim as (
    select * from {{ source('athena_raf', 'claim') }}
),

claimnote as (
    select * from {{ source('athena_raf', 'claimnote') }}
),

claimaudit as (
    select * from {{ source('athena_raf', 'claimaudit') }}
),

-- Aggregate claim notes (one row per claim)
-- Databricks column: CREATEDDATETIME (not CREATEDDATE)
claim_notes_agg as (
    select
        CLAIMID,
        count(*) as note_count,
        max(CREATEDDATETIME) as last_note_date
    from claimnote
    group by CLAIMID
),

-- Aggregate claim audit (one row per claim)
-- Databricks: claimaudit uses ENTITYID as the claim reference, EVENTDATETIME for timestamp
claim_audit_agg as (
    select
        cast(ENTITYID as decimal(12,0)) as CLAIMID,
        count(*) as audit_count,
        max(EVENTDATETIME) as last_audit_date
    from claimaudit
    group by ENTITYID
),

claim_info as (
    select
        cast(c.CLAIMID as int)                            as claim_id,
        cast(c.PATIENTID as int)                          as patient_id,
        c.CLAIMAPPOINTMENTID                              as appointment_id,
        c.PATIENTDEPARTMENTID                             as department_id,
        c.CLAIMCREATEDDATETIME                            as claim_created_date,
        c.CLAIMSERVICEDATE                                as service_date,
        c.PRIMARYCLAIMSTATUS                              as claim_status,
        c.CLAIMPRIMARYPATIENTINSID                        as primary_insurance_id,
        c.RENDERINGPROVIDERID                             as rendering_provider_id,
        -- Notes aggregation
        coalesce(cn.note_count, 0)                        as note_count,
        cn.last_note_date,
        -- Audit aggregation
        coalesce(ca.audit_count, 0)                       as audit_count,
        ca.last_audit_date
    from claim c
    left join claim_notes_agg cn
        on c.CLAIMID = cn.CLAIMID
    left join claim_audit_agg ca
        on c.CLAIMID = ca.CLAIMID
    where c.PATIENTID is not null
)

select * from claim_info
