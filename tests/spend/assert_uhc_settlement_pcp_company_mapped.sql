{{ config(severity='error', tags=['spend', 'finance', 'PAYOR_B', 'VendorBlue', 'settlement', 'coverage']) }}

/*
  Hard-fail: every PCP carrying settlement dollars must map to a known company.

  int_spend__uhc_pcp_company labels a PCP 'Unmapped' when it appears under no
  known Healthcare/VendorBlue TIN. If such a PCP also carries settlement revenue or
  recognized cost on the statement, the Healthcare/VendorBlue decomposition is
  silently mis-booked (the dollars land in an 'Unmapped' bucket instead of a real
  company). This catches a new/changed PCP TIN at build time so the crosswalk is
  updated rather than the split quietly drifting.
*/

select
    release_month,
    company,
    cms_revenue,
    total_medical_cost
from {{ ref('int_spend__uhc_settlement_by_company') }}
where company = 'Unmapped'
  and (coalesce(cms_revenue, 0) <> 0 or coalesce(total_medical_cost, 0) <> 0)
