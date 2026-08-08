{# Verifies that mart_bcr is a lossless pivot of mart_bcr_detail at the
   (context, claim) grain. Fails if any group drifts by >= $0.01. #}

{{ config(severity='error', tags=['marts_bi_v3', 'bcr', 'balance']) }}

with detail_pivot as (
    select
        context_id,
        claim_id,
        sum(case when transaction_class = 'CHARGE'      then amount else 0 end) as charge_amount,
        sum(case when transaction_class = 'PAYMENT'     then amount else 0 end) as payment_amount,
        sum(case when transaction_class = 'ADJUSTMENT'  then amount else 0 end) as adjustment_amount,
        sum(case when transaction_class = 'TRANSFERIN'  then amount else 0 end) as transfer_in_amount,
        sum(case when transaction_class = 'TRANSFEROUT' then amount else 0 end) as transfer_out_amount
    from {{ ref('mart_bcr_detail') }}
    -- Mirror the gold filter applied in mart_bcr: immaterial penny/zero
    -- charge & payment lines are excluded from the rollup. The detail model
    -- itself stays unfiltered (assert_bcr_balances_to_factactivity covers that).
    where not (transaction_class in ('CHARGE', 'PAYMENT') and abs(coalesce(amount, 0)) < {{ var('bcr_gold_min_amount') }})
    group by 1, 2
),

bcr as (
    select
        context_id,
        claim_id,
        charge_amount,
        payment_amount,
        adjustment_amount,
        transfer_in_amount,
        transfer_out_amount
    from {{ ref('mart_bcr') }}
)

select
    coalesce(d.context_id, b.context_id) as context_id,
    coalesce(d.claim_id, b.claim_id)     as claim_id,
    round(coalesce(b.charge_amount, 0)      - coalesce(d.charge_amount, 0), 2) as diff_charge,
    round(coalesce(b.payment_amount, 0)     - coalesce(d.payment_amount, 0), 2) as diff_payment,
    round(coalesce(b.adjustment_amount, 0)  - coalesce(d.adjustment_amount, 0), 2) as diff_adjustment,
    round(coalesce(b.transfer_in_amount, 0) - coalesce(d.transfer_in_amount, 0), 2) as diff_transfer_in,
    round(coalesce(b.transfer_out_amount, 0)- coalesce(d.transfer_out_amount, 0), 2) as diff_transfer_out
from detail_pivot d
full outer join bcr b
    on coalesce(b.context_id, -1) = coalesce(d.context_id, -1)
   and coalesce(b.claim_id, -1)   = coalesce(d.claim_id, -1)
where abs(coalesce(b.charge_amount, 0)      - coalesce(d.charge_amount, 0))      >= 0.01
   or abs(coalesce(b.payment_amount, 0)     - coalesce(d.payment_amount, 0))     >= 0.01
   or abs(coalesce(b.adjustment_amount, 0)  - coalesce(d.adjustment_amount, 0))  >= 0.01
   or abs(coalesce(b.transfer_in_amount, 0) - coalesce(d.transfer_in_amount, 0)) >= 0.01
   or abs(coalesce(b.transfer_out_amount, 0)- coalesce(d.transfer_out_amount, 0))>= 0.01
