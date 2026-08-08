{{
    config(
        materialized='view',
        tags=['quality', 'hedis', 'intermediate', 'dev-4296']
    )
}}

-- intermediate — DEV-4296 · int_quality__diabetes_cohort
-- EXPLICIT diabetes registry — replaces the v1 "lean on Athena QM" denominator for the diabetes
-- condition-gated quality measures (EED, KED, GSD). Federation-SAFE: reads the Delta replica
-- athenahealth.athenaone.claimdiagnosis / .claim — NOT the federation-blocked problem list
-- (patientproblem, DEV-4300). Pattern mirrors int_patient_chronic_conditions.claims_dx.
--
-- Identification: >=1 diabetes ICD-10 dx (E08, E09, E10, E11, E13 — dotless) on a CLOSED/BILLED
-- claim in the measurement year + prior year (24-month) lookback.
--
-- v1 CAVEAT: this is a >=1-claim cohort, NOT the full NCQA GSD identification (which also needs
-- 2-visit logic / dispensed diabetes meds). Flagged for enhancement; it is an explicit, contract-
-- style, QM-INDEPENDENT denominator (so contract-eligible diabetics the QM never measured still
-- surface as gaps — the reconciliation point).

{% set my = var('measurement_year', modules.datetime.date.today().year) %}

with claims_dx as (
    select distinct
        cast(cl.patientid as bigint)            as patient_id,
        replace(cd.diagnosiscode, '.', '')      as dx
    from athenahealth.athenaone.claimdiagnosis cd
    inner join athenahealth.athenaone.claim cl
        on cd.claimid = cl.claimid
    where cd.deleteddatetime is null
      and cd.diagnosiscodesetname = 'ICD10'
      and cl.primaryclaimstatus in ('CLOSED', 'BILLED')
      and cl.claimservicedate >= add_months(to_date('{{ my }}-12-31'), -24)
),

diabetes_dx as (
    select distinct patient_id
    from claims_dx
    where dx rlike '^E0[89]' or dx rlike '^E1[013]'
)

select
    patient_id,
    true                                        as has_diabetes
from diabetes_dx
