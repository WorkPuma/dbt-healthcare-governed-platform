/*
  Domain test (date logic): a claim cannot be paid before the service occurred.
  On int_spend__claims_detail, paid_date must be on/after claim_service_date.
  A paid_date earlier than the service date signals a date-parse/sign error in a
  payor feed that would mis-bucket the cost into the wrong service_month.

  Severity: warn -- surfaces feed date anomalies for review without blocking.
  Returns offending lines (0 = pass).
*/

{{ config(severity='warn', tags=['spend', 'data_quality', 'date_logic']) }}

select
    payor,
    claim_line_key,
    claim_service_date,
    paid_date,
    concat('paid_date ', cast(paid_date as string),
           ' precedes service date ', cast(claim_service_date as string),
           ' (', payor, ')') as failure_message
from {{ ref('int_spend__claims_detail') }}
where paid_date is not null
  and claim_service_date is not null
  and paid_date < claim_service_date
