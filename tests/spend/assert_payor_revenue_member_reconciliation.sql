/*
  Test: payor revenue + member counts reconcile to the restatement-deduped raw

  The PAYOR_A MMR and the PAYOR_B revenue extract are CUMULATIVE: each monthly file
  restates prior months, so the SAME paid dollars recur across files. The only
  correct total is the latest restatement per service/payment month. This test
  pins every "higher" model to that single source of truth so any fan-out
  (e.g. a crosswalk that emits '123' and '123.0' for one person, doubling the
  member's revenue) or restatement double-count HARD FAILS instead of silently
  inflating the P&L.

  Source of truth (per payor):
    - PAYOR_A: stg_payor__payor_alpha_mmr, keep latest load per payment-row key
            (member, contract, PBP, segment, adj reason, transaction_month,
            earned_month), revenue = SUM(tot_ma_pmt), members = COUNT(DISTINCT person),
            member_months = COUNT(DISTINCT person x earned_month)
    - PAYOR_B : raw_uhc_revenue, keep max(release_date) per (year, month),
            revenue = SUM(gross_revenue), members = COUNT(DISTINCT member_alt_id),
            member_months = COUNT(DISTINCT member_alt_id x year x month)

  Checked models:
    - int_finraf__payor_paid_actuals  (revenue + member count + member_months)
    - int_spend__member_month         (revenue + member count; member_months NOT compared
                                       -- it EXPLODES multi-month service windows, an
                                       exploded-window semantic that matches an exploded
                                       SOT, not the start-month SOT used for int_finraf)
    - fct_spend__patient_month        (revenue conservation; member grain is identity)
    - fct_raf__member_revenue         (revenue conservation; member grain is identity)

  Revenue tolerance is $1 (service-window allocation divides by month count, so a
  few cents of float drift is expected). Member counts and member-months must match
  EXACTLY for the payor_member_id-grained model. The SOT key includes payment_year,
  matching int_finraf's per-year grain when a retro adjustment pays the same
  member/service-month in more than one payment year.
  Passes only when zero rows are returned.
*/

{{ config(severity='error', tags=['spend', 'raf', 'reconciliation', 'no_duplication']) }}

with payor_alpha_sot as (
    select
        'PAYOR_A'                                                          as payor,
        sum(try_cast(nullif(tot_ma_pmt, '') as double))                 as sot_revenue,
        count(distinct regexp_replace(trim(payor_alphamn_pers_id), '\\.0$', '')) as sot_members,
        -- Member-months = DISTINCT (member x earned_month) over the
        -- restatement-deduped set. Mirrors staging temporal aliases used in
        -- int_finraf__payor_paid_actuals so the model and SOT move together.
        count(distinct concat(
            regexp_replace(trim(payor_alphamn_pers_id), '\\.0$', ''),
            ':',
            earned_month
        ))                                                              as sot_member_months
    from (
        -- Mirror MODEL dedup: latest load per payment-row key (not global
        -- max(_loaded_at) per month — that drops members omitted from a
        -- partial later restatement).
        select payor_alphamn_pers_id, tot_ma_pmt, payment_date,
               earned_month, transaction_month, _loaded_at
        from {{ ref('stg_payor__payor_alpha_mmr') }}
        where payor_alphamn_pers_id is not null
          and payment_date is not null
          and trim(payment_date) <> ''
          and substr(trim(payment_date), 1, 4) rlike '^[0-9]{4}$'
        qualify row_number() over (
            partition by
                regexp_replace(trim(payor_alphamn_pers_id), '\\.0$', ''),
                coalesce(trim(mco_contract_number), ''),
                coalesce(trim(plan_benefit_package_id), ''),
                coalesce(trim(segment_id), ''),
                coalesce(adjustment_reason_code_norm, ''),
                transaction_month,
                earned_month
            order by _loaded_at desc, source_filename desc
        ) = 1
    )
),

uhc_sot as (
    select
        'PAYOR_B'                                              as payor,
        sum({{ clean_numeric_string('gross_revenue') }})   as sot_revenue,
        count(distinct trim(member_alt_id))                as sot_members,
        -- Member-months = DISTINCT (member x revenue_year x revenue_month) over
        -- the latest-release-deduped extract. PAYOR_B's revenue_month IS the service
        -- month, so this mirrors uhc_agg's count(distinct revenue_month) rollup.
        count(distinct concat(
            trim(member_alt_id), ':',
            trim(cast(revenue_year as string)), ':',
            lpad(trim(revenue_month), 2, '0')
        ))                                                 as sot_member_months
    from (
        select member_alt_id, gross_revenue, revenue_year, revenue_month, release_date
        from {{ source('payor', 'raw_uhc_revenue') }}
        where member_alt_id is not null
          and trim(member_alt_id) <> ''
          and trim(cast(revenue_year as string)) rlike '^[0-9]{4}$'
          and trim(revenue_month) <> ''
        qualify release_date = max(release_date) over (
            partition by try_cast(revenue_year as int), trim(revenue_month)
        )
    )
),

sot as (
    select * from payor_alpha_sot
    union all
    select * from uhc_sot
),

-- payor_member_id-grained models: both revenue AND distinct member must match
finraf as (
    select 'int_finraf__payor_paid_actuals' as model, payor,
           sum(paid_total_revenue) as revenue,
           count(distinct payor_member_id) as members,
           sum(member_months) as member_months
    from {{ ref('int_finraf__payor_paid_actuals') }}
    group by payor
),

member_month as (
    select 'int_spend__member_month' as model, payor,
           sum(revenue_amount) as revenue,
           count(distinct payor_member_id) as members,
           -- member_months is intentionally NOT compared here: int_spend__member_month
           -- EXPLODES multi-month service windows (one row per covered service month),
           -- so its member-month count is an exploded-window semantic that reconciles
           -- to an exploded SOT, not the start-month SOT used for int_finraf. Revenue
           -- + member count are still pinned.
           cast(null as bigint) as member_months
    from {{ ref('int_spend__member_month') }}
    group by payor
),

-- identity-grained facts: revenue must be CONSERVED (member grain intentionally
-- collapses to identity, so member count + member-months are not pinned here)
fct_spend as (
    select 'fct_spend__patient_month' as model, payor,
           sum(revenue_amount) as revenue,
           cast(null as bigint) as members,
           cast(null as bigint) as member_months
    from {{ ref('fct_spend__patient_month') }}
    group by payor
),

fct_raf as (
    select 'fct_raf__member_revenue' as model, payor,
           sum(paid_total_revenue) as revenue,
           cast(null as bigint) as members,
           cast(null as bigint) as member_months
    from {{ ref('fct_raf__member_revenue') }}
    group by payor
),

checks as (
    select * from finraf
    union all select * from member_month
    union all select * from fct_spend
    union all select * from fct_raf
),

-- Expected model x payor matrix so a missing model/payor combination cannot
-- disappear via an inner join before the comparison (full outer on the matrix).
expected_matrix as (
    select m.model, p.payor
    from (
        select 'int_finraf__payor_paid_actuals' as model
        union all select 'int_spend__member_month'
        union all select 'fct_spend__patient_month'
        union all select 'fct_raf__member_revenue'
    ) m
    cross join (
        select 'PAYOR_A' as payor
        union all select 'PAYOR_B'
    ) p
),

joined as (
    select
        e.model,
        e.payor,
        c.revenue,
        c.members,
        c.member_months,
        s.sot_revenue,
        s.sot_members,
        s.sot_member_months
    from expected_matrix e
    left join checks c
        on c.model = e.model
       and c.payor = e.payor
    left join sot s
        on s.payor = e.payor
)

select
    j.model,
    j.payor,
    round(j.revenue, 2)                                       as model_revenue,
    round(j.sot_revenue, 2)                                   as sot_revenue,
    round(coalesce(j.revenue, 0) - coalesce(j.sot_revenue, 0), 2) as revenue_diff,
    j.members                                                 as model_members,
    j.sot_members,
    j.member_months                                           as model_member_months,
    j.sot_member_months,
    abs(coalesce(j.member_months, 0) - coalesce(j.sot_member_months, 0))
                                                              as member_month_diff,
    case
        when j.sot_revenue is null
            then 'MISSING_SOT_PAYOR'
        when j.revenue is null
            then 'MISSING_MODEL_PAYOR'
        when abs(coalesce(j.revenue, 0) - coalesce(j.sot_revenue, 0)) > 1.0
            then 'REVENUE_MISMATCH'
        when j.members is not null and j.members <> j.sot_members
            then 'MEMBER_COUNT_MISMATCH'
        when j.member_months is not null
             and j.member_months <> j.sot_member_months
            then 'MEMBER_MONTH_MISMATCH'
    end                                                        as failure_reason
from joined j
where j.sot_revenue is null
   or j.revenue is null
   or abs(coalesce(j.revenue, 0) - coalesce(j.sot_revenue, 0)) > 1.0
   or (j.members is not null and j.members <> j.sot_members)
   or (j.member_months is not null and j.member_months <> j.sot_member_months)
