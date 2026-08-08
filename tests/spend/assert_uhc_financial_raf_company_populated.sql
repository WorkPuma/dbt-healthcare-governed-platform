{{ config(severity='error', tags=['spend', 'finance', 'PAYOR_B', 'VendorBlue', 'raf', 'coverage']) }}

/*
  Hard-fail: the FINANCIAL paid-RAF surface must be populated for BOTH PAYOR_B books.

  The whole point of the financial (cms_paid_raf) RAF surface is that it splits by
  company — unlike the claims/HCC-derived payment_raf_score, the CMS-paid factor is
  on the revenue file for every paid member-month, VendorBlue included. This test
  guards the core promise: any payor in (PAYOR_B, VendorBlue) book with paid
  member-months must carry a positive financial paid-RAF numerator. If VendorBlue
  (or PAYOR_B) comes back null/zero here, the financial split has silently regressed
  to Healthcare-only. (Financial expected revenue is intentionally NOT asserted —
  it additionally depends on county-benchmark resolution, which can legitimately
  be missing for a month; the RAF numerator only needs the revenue-file factor.)

  Two ways to fail:
   1) value quality — a paid member-month carries no positive financial RAF; and
   2) completeness — a whole book ('PAYOR_B' or 'VendorBlue') is absent from the mart
      entirely, which a value-only check would silently pass.
*/

with bad_value as (
    select
        payor,
        cast(service_month as string)            as detail,
        'no positive financial RAF for paid member-months' as failure_reason
    from {{ ref('mart_medical_spending') }}
    where payor in ('PAYOR_B', 'VendorBlue')
      and coalesce(member_months, 0) > 0
      and coalesce(cms_paid_raf_score_sum, 0) <= 0
),

present_books as (
    select distinct payor
    from {{ ref('mart_medical_spending') }}
    where payor in ('PAYOR_B', 'VendorBlue')
      and coalesce(member_months, 0) > 0
),

missing_book as (
    select
        expected.payor,
        cast(null as string)                     as detail,
        'book absent from mart entirely (financial split regressed)' as failure_reason
    from (select 'PAYOR_B' as payor union all select 'VendorBlue') expected
    left join present_books p on p.payor = expected.payor
    where p.payor is null
)

select payor, detail, failure_reason from bad_value
union all
select payor, detail, failure_reason from missing_book
