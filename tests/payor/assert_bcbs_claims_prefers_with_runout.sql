/*
  Completeness-first series preference (TIC-7777).

  When an incurred month has at least one with_runout snapshot and the chosen
  latest-release snapshot is not with_runout (no_runout or unspecified), that
  is a regression of the maturity preference (coverage / material-completeness
  gates still win first — this test only fires when a with_runout row exists
  for the same incurred month at all).

  Severity WARN: sparse with_runout cuts can legitimately lose to a denser
  no_runout / unspecified snapshot via the 90% material-completeness gate.
*/

{{ config(severity='warn') }}

with latest as (
    select distinct
        incurred_month,
        source_filename,
        claims_maturity_series
    from {{ ref('int_payor__payor_alpha_claims_normalized') }}
    where is_latest_release = true
),

has_with_runout as (
    select distinct incurred_month
    from {{ ref('int_payor__payor_alpha_claims_normalized') }}
    where claims_maturity_series = 'with_runout'
)

select
    l.incurred_month,
    l.source_filename,
    l.claims_maturity_series
from latest l
inner join has_with_runout w
    on l.incurred_month = w.incurred_month
where not (l.claims_maturity_series <=> 'with_runout')
