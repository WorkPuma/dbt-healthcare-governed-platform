{# Verifies that mart_bcr_cpt is a lossless pivot of mart_bcr_detail at the
   (context, claim, charge, CPT) grain across every pivoted transaction_class.
   Fails if any group drifts by >= $0.01. #}

{{ config(severity='error', tags=['marts_bi_v3', 'bcr', 'balance']) }}

with detail_pivot as (
    select
        context_id,
        claim_id,
        charge_id,
        procedure_code,
        sum(case when transaction_class = 'CHARGE'      then amount else 0 end) as charge_amount,
        sum(case when transaction_class = 'PAYMENT'     then amount else 0 end) as payment_amount,
        sum(case when transaction_class = 'ADJUSTMENT'  then amount else 0 end) as adjustment_amount,
        sum(case when transaction_class = 'TRANSFERIN'  then amount else 0 end) as transfer_in_amount,
        sum(case when transaction_class = 'TRANSFEROUT' then amount else 0 end) as transfer_out_amount
    from {{ ref('mart_bcr_detail') }}
    -- Mirror the gold filter applied in mart_bcr_cpt: immaterial penny/zero
    -- charge & payment lines are excluded from the rollup. The detail model
    -- itself stays unfiltered (assert_bcr_balances_to_factactivity covers that).
    where not (transaction_class in ('CHARGE', 'PAYMENT') and abs(coalesce(amount, 0)) < {{ var('bcr_gold_min_amount') }})
    group by 1, 2, 3, 4
),

cpt as (
    select
        context_id,
        claim_id,
        charge_id,
        procedure_code,
        charge_amount,
        payment_amount,
        adjustment_amount,
        transfer_in_amount,
        transfer_out_amount
    from {{ ref('mart_bcr_cpt') }}
)

select
    coalesce(d.context_id, c.context_id)       as context_id,
    coalesce(d.claim_id, c.claim_id)           as claim_id,
    coalesce(d.charge_id, c.charge_id)         as charge_id,
    coalesce(d.procedure_code, c.procedure_code) as procedure_code,
    round(coalesce(c.charge_amount, 0)      - coalesce(d.charge_amount, 0), 2) as diff_charge,
    round(coalesce(c.payment_amount, 0)     - coalesce(d.payment_amount, 0), 2) as diff_payment,
    round(coalesce(c.adjustment_amount, 0)  - coalesce(d.adjustment_amount, 0), 2) as diff_adjustment,
    round(coalesce(c.transfer_in_amount, 0) - coalesce(d.transfer_in_amount, 0), 2) as diff_transfer_in,
    round(coalesce(c.transfer_out_amount, 0)- coalesce(d.transfer_out_amount, 0), 2) as diff_transfer_out
from detail_pivot d
full outer join cpt c
    on  coalesce(c.context_id, -1)     = coalesce(d.context_id, -1)
    and coalesce(c.claim_id, -1)       = coalesce(d.claim_id, -1)
    and coalesce(c.charge_id, -1) = coalesce(d.charge_id, -1)
    and coalesce(c.procedure_code, '') = coalesce(d.procedure_code, '')
where abs(coalesce(c.charge_amount, 0)      - coalesce(d.charge_amount, 0))      >= 0.01
   or abs(coalesce(c.payment_amount, 0)     - coalesce(d.payment_amount, 0))     >= 0.01
   or abs(coalesce(c.adjustment_amount, 0)  - coalesce(d.adjustment_amount, 0))  >= 0.01
   or abs(coalesce(c.transfer_in_amount, 0) - coalesce(d.transfer_in_amount, 0)) >= 0.01
   or abs(coalesce(c.transfer_out_amount, 0)- coalesce(d.transfer_out_amount, 0))>= 0.01
