/*
  Domain test (grain convention): service_month on the spend fact is the
  member-month key and must always be the first calendar day of the month
  (date_trunc('month', ...)). A non-first-of-month value would split a single
  member-month into multiple rows and break the (payor, patient, service_month)
  grain and every PMPM denominator.

  Returns offending rows (0 = pass).
*/

select
    fct_spend__patient_month_id,
    service_month
from {{ ref('fct_spend__patient_month') }}
where service_month is not null
  and service_month <> date_trunc('month', service_month)
