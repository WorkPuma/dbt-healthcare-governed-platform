{{
    config(
        materialized='table',
        schema='marts_bi_v3',
        alias='mart_hcc_provider_category_breakdown',
        tags=['marts_bi_v3', 'cube', 'BIPlatform', 'v3_synced', 'hcc'],
        meta={
            'servingdb_sync': true,
            'servingdb_mode': 'SNAPSHOT',
            'servingdb_snapshot_reason': 'Report-shaped provider x CCSR x HCC aggregation; full rebuild each run matches the legacy ServingDB view and keeps category rollups consistent.'
        }
    )
}}

/*
  mart_hcc_provider_category_breakdown — provider x CCSR body-system x HCC
  status breakdown, at both the leaf (provider x category x hcc_code) and
  the parent category (provider x category) grain in the same row.

  Ports the ServingDB-local `mart_hcc_provider_category_breakdown` view
  (previously created ad hoc by scripts/servingdb/hcc_capture-seed.sql, which
  cannot run in staging/prod) into a real dbt model so it ships via CI +
  servingdb_sync instead of a local-only Postgres view.

  Grain: one row per (provider_name x ccsr_body_system_code x
  category_description x hcc_code). The category-level (st_*, hcc_*)
  columns are repeated across every hcc_code row within the same category —
  same shape as the source ServingDB view.
*/

with base as (
    select
        r.provider_name,
        r.ccsr_body_system_code,
        r.category_description,
        r.hcc_code,
        r.suggestion_status,
        r.patient_id || '|' || r.icd10_code as pid_icd,
        r.patient_id || '|' || r.hcc_code   as pid_hcc,
        case trim(upper(r.suggestion_status))
            when 'ACCEPTED' then 1
            when 'HELD'     then 2
            when 'REJECTED' then 3
            else 4
        end as sp
    from {{ ref('mart_hcc_rolled') }} r
    where r.provider_name is not null
      and r.hcc_code is not null
      and r.hcc_code <> ''
      and r.ccsr_body_system_code is not null
),

hcc_win as (
    select pid_hcc, min(sp) as win_sp
    from base
    group by pid_hcc
),

b as (
    select base.*, hw.win_sp
    from base
    inner join hcc_win hw on hw.pid_hcc = base.pid_hcc
),

leaf as (
    select
        provider_name,
        ccsr_body_system_code,
        category_description,
        hcc_code,
        count(distinct pid_icd) as hcc_icd_count,
        count(distinct pid_icd) filter (where suggestion_status = 'REJECTED')      as hcc_st_rejected,
        count(distinct pid_icd) filter (where suggestion_status = 'HELD')         as hcc_st_held,
        count(distinct pid_icd) filter (where suggestion_status = 'ACCEPTED')     as hcc_st_accepted,
        count(distinct pid_icd) filter (where suggestion_status = 'NOT ADDRESSED') as hcc_st_notaddr
    from b
    group by provider_name, ccsr_body_system_code, category_description, hcc_code
),

cat as (
    select
        provider_name,
        ccsr_body_system_code,
        category_description,
        count(distinct pid_icd) as category_total,
        count(distinct pid_hcc) as distinct_hcc_count,
        count(distinct pid_icd) filter (where suggestion_status = 'REJECTED')      as st_rejected,
        count(distinct pid_icd) filter (where suggestion_status = 'HELD')         as st_held,
        count(distinct pid_icd) filter (where suggestion_status = 'ACCEPTED')     as st_accepted,
        count(distinct pid_icd) filter (where suggestion_status = 'NOT ADDRESSED') as st_notaddr,
        count(distinct pid_hcc) filter (where win_sp = 1) as hcc_accepted,
        count(distinct pid_hcc) filter (where win_sp = 2) as hcc_held,
        count(distinct pid_hcc) filter (where win_sp = 3) as hcc_rejected,
        count(distinct pid_hcc) filter (where win_sp = 4) as hcc_notaddr
    from b
    group by provider_name, ccsr_body_system_code, category_description
),

catp as (
    select
        cat.*,
        round(
            100.0 * cast(category_total as decimal(18, 4))
            / nullif(cast(sum(category_total) over (partition by provider_name, ccsr_body_system_code) as decimal(18, 4)), 0),
            1
        ) as pct_of_cell
    from cat
)

select
    l.provider_name,
    l.ccsr_body_system_code,
    l.category_description,
    l.hcc_code,
    l.hcc_icd_count,
    c.category_total as distinct_icd_count,
    c.distinct_hcc_count,
    c.pct_of_cell,
    c.st_rejected,
    c.st_held,
    c.st_accepted,
    c.st_notaddr,
    l.hcc_st_rejected,
    l.hcc_st_held,
    l.hcc_st_accepted,
    l.hcc_st_notaddr,
    c.hcc_accepted,
    c.hcc_held,
    c.hcc_rejected,
    c.hcc_notaddr,
    current_timestamp() as source_updated_at
from leaf l
inner join catp c
    on c.provider_name = l.provider_name
   and c.ccsr_body_system_code = l.ccsr_body_system_code
   and c.category_description = l.category_description
