/*
  Decision MLR must be populated exactly for COMPLETE monthly books and remain
  null for missing-revenue, certified-unavailable, and claims-immature periods.

  Passes = zero rows.
*/

{{ config(severity='error', tags=['spend', 'reconciliation']) }}

select
    payor,
    service_month,
    spend_completeness_status,
    mlr,
    case
        when spend_completeness_status = 'COMPLETE' and mlr is null
            then 'COMPLETE_PERIOD_MLR_MISSING'
        when spend_completeness_status <> 'COMPLETE' and mlr is not null
            then 'INCOMPLETE_PERIOD_MLR_POPULATED'
    end as failure_reason
from {{ ref('mart_medical_spending') }}
where (spend_completeness_status = 'COMPLETE' and mlr is null)
   or (spend_completeness_status <> 'COMPLETE' and mlr is not null)
