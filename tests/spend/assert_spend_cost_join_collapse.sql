/*
  Test: PAYOR_A/PAYOR_B cost join collapse — revenue pre-aggregation before cost join

  int_spend__member_month is grained on payor_member_id; EMPI merge can map
  several member ids to one patient_id/identity_id. fct_spend__patient_month
  collapses revenue to (payor, patient_id, service_month) BEFORE the FULL OUTER
  join to int_spend__claims_rollup. Without that collapse, cost fans out and
  PAYOR_A MLR was inflated ~24%.

  This test pins total cost at the payor grain: fct_spend must equal the rollup
  source exactly (within $1 float tolerance per payor).
*/

{{ config(severity='error', tags=['spend', 'finance', 'integrity', 'no_duplication']) }}

with rollup as (
    select
        payor,
        sum(total_cost) as rollup_cost
    from {{ ref('int_spend__claims_rollup') }}
    group by payor
),

fact as (
    select
        payor,
        sum(total_cost) as fact_cost
    from {{ ref('fct_spend__patient_month') }}
    group by payor
)

select
    coalesce(r.payor, f.payor)              as payor,
    r.rollup_cost,
    f.fact_cost,
    abs(coalesce(r.rollup_cost, 0) - coalesce(f.fact_cost, 0)) as cost_delta
from rollup r
full outer join fact f
    on r.payor = f.payor
where abs(coalesce(r.rollup_cost, 0) - coalesce(f.fact_cost, 0)) > 1.0
