/*
  Domain test (claims maturity): the is_month_mature flag on
  fct_spend__patient_month must agree with months_of_runout against the maturity
  threshold (var spend_maturity_months, default 3). Guards against the flag and
  the underlying runout drifting apart if either definition is edited.

  Test passes if zero rows returned.
*/

{{ config(severity='error', tags=['spend', 'data_quality', 'ibnr_maturity']) }}

select
    payor,
    service_month,
    months_of_runout,
    is_month_mature,
    concat('Maturity flag (', cast(is_month_mature as string),
           ') disagrees with months_of_runout ', cast(months_of_runout as string),
           ' vs threshold {{ var("spend_maturity_months", 3) }}') as failure_message
from {{ ref('fct_spend__patient_month') }}
where is_month_mature <> (months_of_runout >= {{ var('spend_maturity_months', 3) }})
