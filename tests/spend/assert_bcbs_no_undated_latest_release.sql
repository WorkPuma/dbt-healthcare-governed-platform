/*
  Guard: authoritative PAYOR_A claim lines must have a parseable service date.

  The FY2025 annual Claims*.txt extract ships dates as YYYY/MM/DD. When
  parse_claim_date lacked that format, every DOS/paid date became NULL, the
  null incurred_month partition won is_latest_release, and spend dropped the
  entire ~$9.48M file on `claim_service_date is not null`.

  Also fails when the latest authoritative release has zero rows (presence),
  so an empty/missing release cannot silently pass.

  Severity: error. Returns undated authoritative rows (aggregated).
*/

{{ config(severity='error', tags=['spend', 'PAYOR_A', 'claims', 'data_quality']) }}

with undated as (
    select
        coalesce(source_filename, '(unknown)') as source_filename,
        release_period_date,
        count(*) as undated_rows,
        sum(plan_paid_amount) as undated_paid,
        concat(
            'PAYOR_A authoritative release has ', cast(count(*) as string),
            ' undated claim lines ($',
            cast(round(sum(coalesce(plan_paid_amount, 0)), 2) as string),
            ') in ', coalesce(source_filename, '(unknown)'),
            ' — date parse/regression failure'
        ) as failure_message
    from {{ ref('int_payor__payor_alpha_claims_normalized') }}
    where is_latest_release = true
      and (
          claim_service_date is null
          or incurred_month is null
          or (service_date_first is null and service_date_last is null)
      )
    group by 1, 2
    having count(*) > 0
),

presence as (
    select
        '(all)' as source_filename,
        cast(null as date) as release_period_date,
        cast(0 as bigint) as undated_rows,
        cast(0 as decimal(18, 2)) as undated_paid,
        'PAYOR_A authoritative release presence failure: is_latest_release has zero rows'
            as failure_message
    where not exists (
        select 1
        from {{ ref('int_payor__payor_alpha_claims_normalized') }}
        where is_latest_release = true
    )
)

select * from undated
union all
select * from presence
