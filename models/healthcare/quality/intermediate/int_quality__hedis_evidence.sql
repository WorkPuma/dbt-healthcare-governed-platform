-- DEV-4296 · int_quality__hedis_evidence (V3 Databricks dbt)
-- THE TRUE HEDIS evidence table (this name was previously mis-used by the all-codes pool, now
-- renamed int_quality__code_pool). Athena Quality-Management-engine NATIVE.
--
-- Grain: one row per patient × measure × service_date (best result per measure, deduped).
-- "Patient X satisfied measure Y on date Z, result R." This is what athena's QM engine already
-- computed — the baseline. The code_pool is the supplemental net to find MORE patients than this.
--
-- Sources: QMRESULT (status) + P4PRESULTDATA (EAV result value) + P4PRESULT→P4PMEASURE (category)
--          + CHART (patient-id fallback when QMRESULT.PATIENTID depopulated).
--   NOTE: qmresult / chart / p4presultdata resolve via source('athenahealth_metadata', ...);
--         p4presult / p4pmeasure are declared on source('athenahealth', ...) on main.
-- Result pivot lifted from REDACTED_PATH — the result VALUE
-- lives under a MEASURE-TYPE-SPECIFIC P4PRESULTDATA.KEY (labs vs BP vs questionnaire).
-- Open gaps (NULL satisfied_date, 'Needs Data'/'Out of Range') are KEPT — they ARE the point.
-- COMPUTE: incremental merge on LASTUPDATED + 7d lookback; measurement-year filter is a CONSUMER
--          concern (never a blanket year() here). ~685K rows, slow-growing → cheap.
-- STAGING: reads thin stg_athena__ wrappers (qmresult / p4presultdata / p4presult / p4pmeasure /
--          qm_chart) — 1:1 over athenahealth.athenaone (Delta); deletes/archive dropped at staging.
-- PROVIDER CAVEAT: QMRESULT stores one row per patient×measure×date PER
--          PROVIDER, plus per program and per result-id — multiple
--          rows/group. The dedup below collapses these to ONE clinical fact, keeping one provider_id
--          (by SATISFIED → non-null result → latest). That provider_id is NOT the submission NPI —
--          downstream payer sidecars must re-attribute via roster + npi_confidence_score.

{{ config(
    materialized        = 'incremental',
    incremental_strategy = 'merge',
    unique_key          = 'evidence_key',
    on_schema_change    = 'append_new_columns',
    matched_condition   = 't.last_updated <> s.last_updated'
) }}

with qm as (
    select
        p4p_result_id,
        patient_id,
        chart_id,
        provider_id,
        p4p_program,
        p4p_measure,
        result_status,
        satisfied_date,
        exclusion_reason,
        last_updated
    from {{ ref('stg_athena__qmresult') }}
    {% if is_incremental() %}
      where last_updated >= (select dateadd(day, -7, max(last_updated)) from {{ this }})
    {% endif %}
),

chart as (
    select chart_id, patient_id as chart_patient_id
    from {{ ref('stg_athena__qm_chart') }}
),

p4presult as (
    select p4p_result_id, p4p_measure_id
    from {{ ref('stg_athena__p4presult') }}
),

p4pmeasure as (
    select p4p_measure_id, category, short_name, measure_type
    from {{ ref('stg_athena__p4pmeasure') }}
),

result_data as (
    select
        p4p_result_id,
        max(case when result_key = 'CLINICALRESULTOBSERVATIONVALUE' then result_value end)                 as lab_value,
        max(case when result_key in ('VITAL.SYSTOLIC','VITALS.BLOODPRESSURE.SYSTOLIC')  then result_value end) as bp_systolic,
        max(case when result_key in ('VITAL.DIASTOLIC','VITALS.BLOODPRESSURE.DIASTOLIC') then result_value end) as bp_diastolic,
        max(case when result_key = 'SCORE' then result_value end)                                          as score_value,
        max(case when result_key = 'OBSERVATIONUNITS' then result_value end)                               as result_units,
        max(case when result_key = 'RESULTDATE' then result_value end)                                     as result_date_raw
    from {{ ref('stg_athena__p4presultdata') }}
    group by p4p_result_id
),

joined as (
    select
        coalesce(qm.patient_id, ch.chart_patient_id)                      as patient_id,
        qm.p4p_measure                                                    as measure,
        coalesce(pm.category, qm.p4p_program)                             as quality_category,
        qm.result_status                                                  as result_status,
        coalesce(qm.satisfied_date, try_cast(rd.result_date_raw as date)) as service_date,
        coalesce(rd.lab_value, rd.bp_systolic, rd.score_value)            as result,
        rd.bp_diastolic                                                   as result_secondary,
        rd.result_units                                                   as result_units,
        qm.provider_id                                                    as provider_id,
        qm.exclusion_reason                                               as exclusion_reason,
        qm.p4p_program                                                    as program,
        qm.p4p_result_id                                                  as p4p_result_id,
        qm.last_updated                                                   as last_updated,
        'system'                                                          as code_origin,
        'qm_engine'                                                       as source_method
    from qm
    left join chart      ch on ch.chart_id = qm.chart_id
    left join p4presult  pr on pr.p4p_result_id = qm.p4p_result_id
    left join p4pmeasure pm on pm.p4p_measure_id = pr.p4p_measure_id
    left join result_data rd on rd.p4p_result_id = qm.p4p_result_id
),

final as (
    select
        md5(concat_ws('||',
            cast(patient_id as string), measure,
            coalesce(cast(service_date as string), 'OPEN')
        ))                                          as evidence_key,
        patient_id,
        measure,
        quality_category,
        result_status,
        service_date,
        result,
        result_secondary,
        result_units,
        provider_id,
        exclusion_reason,
        program,
        p4p_result_id,
        year(service_date)                          as measurement_year,
        last_updated,
        code_origin,
        source_method
    from joined
    where patient_id is not null
    qualify row_number() over (
        partition by patient_id, measure, coalesce(cast(service_date as string), 'OPEN')
        order by case when result_status = 'SATISFIED' then 0 else 1 end,
                 case when result is not null then 0 else 1 end,
                 last_updated desc
    ) = 1
)

select
    evidence_key,
    patient_id,
    measure,
    quality_category,
    result_status,
    service_date,
    result,
    result_secondary,
    result_units,
    provider_id,
    exclusion_reason,
    program,
    p4p_result_id,
    measurement_year,
    last_updated,
    code_origin,
    source_method
from final
