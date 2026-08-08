-- intermediate — DEV-4296 · int_quality__claim_code_evidence (V3 Databricks dbt)
-- THE BILLED branch of the funnel — administrative-credit evidence (the HARD tier).
--
-- WHY: "any point-in-time billed diagnosis locks the correct ICD." HEDIS
-- administrative credit requires the code on a CLAIM, not the problem list. This branch reads the
-- billed ICD-10 directly off claimdiagnosis (the canonical long table) joined to its claim.
--   * code        — claimdiagnosis.DIAGNOSISCODE (already dotless in the replica: 'Z9989','2189');
--                   replace('.','') applied defensively so the accepted-code join (dotless) matches.
--   * patient/DOS — from the parent claim (claim.patientid / claim.claimservicedate).
-- We do NOT need clinicalencounter.claimid (NULL in the replica) — the billed ICD is right here.
-- Claim filter: primaryclaimstatus in ('CLOSED','BILLED') — mirrors int_quality__diabetes_cohort:33.
-- PENDING/HOLD claims are not yet administrative evidence (they ride the closed-encounter branch).
--
-- FALSE-MONTH LAG: claims typically bill several days to a few weeks after service. So `billed`
-- is a CONFIRMATION that arrives LATE — it must UPGRADE closed-encounter evidence (code_pool picks
-- best provenance), NEVER gate it (gating would drop the trailing days of every monthly pull =
-- the false-month gap). This branch carries claim_billed_date
-- + bill_lag_days (like the lab branch carries result_reported_date) for the not-yet-billed
-- worklist — those two extra cols stay HERE and are intentionally NOT pulled into code_pool.
--
-- evidence_provenance = 'billed' (tier 1, hard). See EVIDENCE_PROVENANCE_ARCHITECTURE.md §1/§5.
-- Common funnel schema + evidence_provenance. Layer: intermediate. Deletes dropped inline.

with cd as (
    select
        cast(claimid as string)              as claim_id,
        cast(claimdiagnosisid as string)     as claim_diagnosis_id,
        replace(cast(diagnosiscode as string), '.', '') as diagnosis_code
    from athenahealth.athenaone.claimdiagnosis
    where deleteddatetime is null
      and diagnosiscode is not null
),
cl as (
    select
        cast(claimid as string)                          as claim_id,
        cast(cast(patientid as decimal(38,0)) as string) as patient_id,
        claimservicedate                                 as service_date,
        lastbilleddate1                                  as claim_billed_date,
        primaryclaimstatus                               as claim_status,
        claimcreateddatetime                             as create_date_raw
    from athenahealth.athenaone.claim
    where primaryclaimstatus in ('CLOSED', 'BILLED')
      and claimservicedate is not null
),

billed as (
    select
        cl.patient_id,
        cd.diagnosis_code                    as code,
        cast(null as string)                 as code_modifier,
        cd.diagnosis_code                    as code_raw,
        'ICD10CM'                            as code_type,
        cl.service_date                      as date_of_service,
        'CLAIM_DX'                           as source_table,
        cd.claim_diagnosis_id                as source_record_id,
        cl.claim_billed_date,
        datediff(cl.claim_billed_date, cl.service_date) as bill_lag_days,
        cl.create_date_raw
    from cd
    join cl on cl.claim_id = cd.claim_id
)

select
    patient_id,
    code,
    code_type,
    date_of_service,
    code_raw,
    code_modifier,
    source_table,
    source_record_id,
    year(date_of_service)               as measurement_year,
    'system'                            as code_origin,
    'claim_dx'                          as source_method,
    'submittable'                       as order_status,
    'billed'                            as evidence_provenance,
    claim_billed_date,
    bill_lag_days,
    cast(create_date_raw as date)       as create_date
from billed
