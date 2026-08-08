/*
  Domain test (claims maturity / IBNR signal): the most recent service month's
  cost PMPM should not fall off a cliff versus the trailing months. Medical claims
  arrive with lag, so the latest month is structurally immature -- its paid cost is
  understated until run-out completes. A sharp drop is the symptom of that
  immaturity (Incurred-But-Not-Reported), NOT a real cost decrease, and anything
  consuming the latest month as final will understate MLR/PMPM.

  This is an explicit IBNR/maturity guardrail: the model does not yet carry an
  IBNR completion factor (known modeling gap), so this warns when the latest month
  looks immature relative to a trailing 3-month average.

  Severity: warn. Returns offending payor-months (0 = pass).
*/

{{ config(severity='warn', tags=['spend', 'semantic_guardrail', 'ibnr_maturity']) }}

{% set cliff_frac = var('spend_recent_month_cliff_frac', 0.5) %}
{% set min_mm = var('spend_recent_month_min_mm', 50) %}

with monthly as (
    select
        payor,
        service_month,
        sum(coalesce(total_cost, 0))    as total_cost,
        sum(coalesce(member_months, 0)) as mm
    from {{ ref('fct_spend__patient_month') }}
    group by payor, service_month
),

pmpm as (
    select
        payor,
        service_month,
        mm,
        case when mm > 0 then total_cost / mm end as pmpm
    from monthly
),

latest as (
    select payor, max(service_month) as latest_month
    from monthly
    group by payor
),

latest_pmpm as (
    select p.payor, p.pmpm as latest_pmpm, p.mm
    from pmpm p
    inner join latest l
        on p.payor = l.payor and p.service_month = l.latest_month
),

trailing as (
    select
        p.payor,
        avg(p.pmpm) as trailing_pmpm,
        count(*)    as n_months
    from pmpm p
    inner join latest l
        on p.payor = l.payor
    where p.service_month < l.latest_month
      and p.service_month >= add_months(l.latest_month, -4)
      and p.mm > 0
    group by p.payor
)

select
    lp.payor,
    lp.latest_pmpm,
    t.trailing_pmpm,
    lp.mm,
    concat('Latest-month PMPM $', round(lp.latest_pmpm, 0),
           ' is below ', {{ cliff_frac }} * 100, '% of trailing avg $',
           round(t.trailing_pmpm, 0), ' for ', lp.payor,
           ' (likely immature claims / IBNR)') as failure_message
from latest_pmpm lp
inner join trailing t
    on lp.payor = t.payor
where t.n_months >= 3
  and lp.mm >= {{ min_mm }}
  and t.trailing_pmpm > 0
  and lp.latest_pmpm < {{ cliff_frac }} * t.trailing_pmpm
