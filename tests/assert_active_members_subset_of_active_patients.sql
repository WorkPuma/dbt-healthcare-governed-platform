{{
    config(
        severity='warn',
        tags=['historical', 'membership', 'data_quality']
    )
}}

/*
  Canonical population hierarchy: Active Members must be a strict subset of
  Active Patients (commercial membership population gated on Membership status).

  This test surfaces CURRENT-month accounts where the membership systems
  (SF enrollment + Membership) say "active member" but the canonical computed
  patient status is not Active — SF/Membership lag, or a churned patient still
  enrolled/billed. These rows are the reconciliation queue for the
  membership ops team; warn severity because lag is expected in small
  numbers, but growth here means the systems are drifting apart.

  Historical months are excluded: past mismatches are facts, not actionable.
*/

select count(*) as violation_count
from {{ ref('hist_member_status_monthly') }}
where member_not_active_patient = true
  and status_month = cast(date_trunc('month', current_date()) as date)
having count(*) > 250
