/*
  Guard: raw PAYOR_A claims paid totals must survive staging.

  Staging retains null-CLM_KEY rows when claim_nbr is present
  (`coalesce(clm_key, claim_nbr)`); rows with neither key are dropped.

  This test applies that same claim_key resolution + parse_claim_date(release_date)
  + latest-loaded_at dedupe as staging on the raw side, so only material loss
  (not exact-duplicate collapse) fails CI. Also fails when raw has claims but
  staging is empty (presence).

  Severity: error. Returns offending (source_filename, release_date) pairs.
*/

{{ config(severity='error', tags=['spend', 'PAYOR_A', 'claims', 'parity']) }}

with raw_keyed as (
    -- Same claim_key + release_date contract as stg_payor__payor_alpha_claims:
    -- coalesce(clm_key, claim_nbr), drop rows with neither, parse_claim_date
    -- for release_date (not try_cast — slash vintages must match staging).
    select
        coalesce(nullif(trim(source), ''), '(unknown)') as source_filename,
        {{ parse_claim_date('release_date') }} as release_date_canon,
        coalesce(nullif(trim(clm_key), ''), nullif(trim(claim_nbr), '')) as claim_key_resolved,
        try_cast(trim(claim_line) as int) as claim_line,
        cast({{ clean_numeric_string('plan_paid') }} as decimal(18, 2)) as plan_paid,
        loaded_at,
        file_source,
        source
    from {{ source('payor', 'raw_payor_alpha_claims') }}
    where coalesce(nullif(trim(clm_key), ''), nullif(trim(claim_nbr), '')) is not null
),

raw_resolved as (
    select
        *,
        row_number() over (
            partition by
                claim_key_resolved,
                claim_line,
                release_date_canon
            order by
                loaded_at desc nulls last,
                file_source desc nulls last,
                source desc nulls last
        ) as _rn
    from raw_keyed
),

raw_by_release as (
    select
        source_filename,
        release_date_canon as release_date,
        count(*) as raw_rows,
        sum(plan_paid) as raw_paid
    from raw_resolved
    where _rn = 1
    group by 1, 2
),

stg_by_release as (
    select
        coalesce(nullif(trim(source_filename), ''), '(unknown)') as source_filename,
        release_date,
        count(*) as stg_rows,
        sum(plan_paid_amount) as stg_paid
    from {{ ref('stg_payor__payor_alpha_claims') }}
    group by 1, 2
),

compared as (
    select
        coalesce(r.source_filename, s.source_filename) as source_filename,
        coalesce(r.release_date, s.release_date) as release_date,
        coalesce(r.raw_rows, 0) as raw_rows,
        coalesce(s.stg_rows, 0) as stg_rows,
        coalesce(r.raw_paid, 0) as raw_paid,
        coalesce(s.stg_paid, 0) as stg_paid,
        coalesce(r.raw_rows, 0) - coalesce(s.stg_rows, 0) as dropped_rows,
        coalesce(r.raw_paid, 0) - coalesce(s.stg_paid, 0) as dropped_paid
    from raw_by_release r
    full outer join stg_by_release s
        on r.source_filename <=> s.source_filename
       and r.release_date <=> s.release_date
),

presence_failure as (
    select
        '(all)' as source_filename,
        cast(null as date) as release_date,
        cast(0 as bigint) as raw_rows,
        cast(0 as bigint) as stg_rows,
        cast(0 as decimal(18, 2)) as raw_paid,
        cast(0 as decimal(18, 2)) as stg_paid,
        cast(0 as bigint) as dropped_rows,
        cast(0 as decimal(18, 2)) as dropped_paid,
        'PAYOR_A raw→stage presence failure: raw_payor_alpha_claims has rows but staging has zero eligible releases'
            as failure_message
    where exists (select 1 from {{ source('payor', 'raw_payor_alpha_claims') }})
      and not exists (select 1 from stg_by_release)
)

select
    source_filename,
    release_date,
    raw_rows,
    stg_rows,
    raw_paid,
    stg_paid,
    dropped_rows,
    dropped_paid,
    concat(
        'PAYOR_A raw→stage paid loss for ', source_filename,
        ' / ', cast(release_date as string),
        ': dropped ', cast(dropped_rows as string), ' rows / $',
        cast(round(dropped_paid, 2) as string),
        ' (raw $', cast(round(raw_paid, 2) as string),
        ' → stage $', cast(round(stg_paid, 2) as string), ')'
    ) as failure_message
from compared
where abs(dropped_paid) > 1
   or abs(dropped_rows) > 0
   or (stg_rows = 0 and raw_rows > 0)

union all

select * from presence_failure
