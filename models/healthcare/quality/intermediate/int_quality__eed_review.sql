{{
    config(
        materialized='view',
        tags=['quality', 'hedis', 'intermediate', 'eed', 'dev-4296']
    )
}}

-- intermediate — DEV-4296 · int_quality__eed_review
-- EED review worklist: QM-engine says EED=SATISFIED (athena derived it, including external eye providers)
-- but the patient has NO submittable eye-exam code in athena (external exam, no HH code).
-- Per Q27/Q28 these are MANUAL REVIEW with suggested code 92250 (fundus photography) — NOT auto-submitted.

with qm_eed as (
    select distinct patient_id, max(service_date) as satisfied_date
    from {{ ref('int_quality__hedis_evidence') }}
    where upper(measure) rlike 'EED|RETINAL|EYE EXAM'
      and result_status = 'SATISFIED'
    group by patient_id
),

has_real_code as (
    select distinct patient_id
    from {{ ref('int_quality__measure_dated_evidence') }}
    where measure_type = 'RetEye' and code not rlike '^992[0-9][0-9]$'
)

select
    q.patient_id,
    'RetEye'                                                                                                                               as measure_type,
    q.satisfied_date,
    '92250'                                                                                                                                as suggested_code,
    'CPT'                                                                                                                                  as suggested_code_type,
    'EED QM=SATISFIED but no submittable eye-exam code in athena (external exam) — manual review per Q27/Q28' as review_reason
from qm_eed q
left join has_real_code h on q.patient_id = h.patient_id
where h.patient_id is null
