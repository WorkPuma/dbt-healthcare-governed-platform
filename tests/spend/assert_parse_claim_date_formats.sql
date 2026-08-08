/*
  Guard: parse_claim_date must accept every PAYOR_A date vintage we have seen.

  Formats covered:
    - YYYY-MM-DD (Excel timestamp cast)
    - M/D/YYYY
    - YYYY/MM/DD  (annual Claims*.txt — the FY2025 silent-null regression)
    - YYYYMMDD
    - "NaT" sentinel (pandas Not-a-Time leak from the upstream loader, seen on
      483 rx_fill_date rows in raw_payor_alpha_claims) — must yield NULL, not error.

  Severity: error. Returns any format that fails to parse (or any non-null
  vintage that yields the wrong date). NaT/NULL is the expected null shape, so
  the nat_sentinel row only fails if the macro ever returns a non-NULL garbage
  date for it.
*/

{{ config(severity='error', tags=['spend', 'PAYOR_A', 'claims', 'data_quality']) }}

with samples as (
    select 'iso_dash' as fmt, '2025-11-25' as raw_val, date '2025-11-25' as expected
    union all
    select 'us_slash', '11/25/2025', date '2025-11-25'
    union all
    select 'iso_slash', '2025/11/25', date '2025-11-25'
    union all
    select 'iso_slash_short', '2025/1/5', date '2025-01-05'
    union all
    select 'compact', '20251125', date '2025-11-25'
    union all
    select 'excel_ts', '2025-11-25 00:00:00', date '2025-11-25'
    union all
    select 'nat_sentinel', 'NaT', cast(null as date)
)

select
    fmt,
    raw_val,
    expected,
    {{ parse_claim_date('raw_val') }} as parsed,
    concat(
        'parse_claim_date failed for format ', fmt,
        ' value ', raw_val,
        ' (got ', coalesce(cast({{ parse_claim_date('raw_val') }} as string), 'NULL'),
        ', expected ', cast(expected as string), ')'
    ) as failure_message
from samples
where {{ parse_claim_date('raw_val') }} is distinct from expected
