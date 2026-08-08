{# DEV-4490: KPI months must not extend past the current calendar month.
   Future appointment dates previously leaked into month_dim_spine. #}

{{ config(severity='error', tags=['marts_bi_v3', 'membership', 'balance']) }}

select
    period_start,
    count(*) as row_count
from {{ ref('mart_membership_kpis_monthly') }}
where period_start > date_trunc('month', current_date())::date
group by 1
