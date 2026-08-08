{# Canonical penny-perfect balance gate for the BCR mart family.

   Fails if any (post-month, transaction_class) bucket in mart_bcr_detail
   drifts from athenahealth.financials.activityfact by >= $0.01. This is
   the user-required reconciliation: total charges, payments, adjustments,
   transfers in/out must equal ActivityFact to the penny. #}

{{ config(severity='error', tags=['marts_bi_v3', 'bcr', 'balance']) }}

with bcr as (
    select
        date_trunc('month', post_date) as month_,
        transaction_class,
        sum(amount) as bcr_amount
    from {{ ref('mart_bcr_detail') }}
    group by 1, 2
),

af as (
    select
        date_trunc('month', postdate) as month_,
        upper(type) as transaction_class,
        sum(amount) as af_amount
    from {{ source('athenahealth_financials', 'activityfact') }}
    group by 1, 2
)

select
    coalesce(bcr.month_, af.month_)                       as month_,
    coalesce(bcr.transaction_class, af.transaction_class) as transaction_class,
    coalesce(bcr.bcr_amount, 0)                           as bcr_amount,
    coalesce(af.af_amount, 0)                             as af_amount,
    round(coalesce(bcr.bcr_amount, 0) - coalesce(af.af_amount, 0), 2) as diff_amount
from bcr
full outer join af
    on bcr.month_            = af.month_
   and bcr.transaction_class = af.transaction_class
where abs(coalesce(bcr.bcr_amount, 0) - coalesce(af.af_amount, 0)) >= 0.01
