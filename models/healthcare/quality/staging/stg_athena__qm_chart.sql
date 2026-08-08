-- staging (support) — DEV-4296 · stg_athena__qm_chart (V3 Databricks dbt)
-- QM-engine chart-hop: chart_id -> patient_id fallback when QMRESULT.PATIENTID is depopulated.
--
-- FIX: athenahealth_metadata.chart has NO `patientid`
-- column (only CHARTID/CONTEXTID/NEWCHARTID...). Use the canonical chart->patient crosswalk
-- (raf/shared int_patient_chart_crosswalk, which resolves patient_id via patient.ENTERPRISEID) —
-- the same source int_patient_chronic_conditions uses. ref() so smart-ref reads prod.
select
    chart_id,
    patient_id
from {{ ref('int_patient_chart_crosswalk') }}
