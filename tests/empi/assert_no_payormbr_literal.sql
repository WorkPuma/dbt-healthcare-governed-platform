-- The EMPI identity re-key retired the volatile PAYORMBR:<payor>:<member>
-- synthetic key in favor of the immutable identity_id (H-number). This test
-- fails if ANY surviving financial output still emits a PAYORMBR literal in its
-- entity key columns, which would mean a model was missed in the re-key and a
-- ghost would churn its key (instead of being reported as ONE identity across
-- the ghost -> matched transition).

select 'fct_spend__patient_month' as model, patient_id as offending_key
from {{ ref('fct_spend__patient_month') }}
where patient_id like 'PAYORMBR:%' or identity_id like 'PAYORMBR:%'

union all
select 'fct_raf__member_revenue', cast(patient_id as string)
from {{ ref('fct_raf__member_revenue') }}
where cast(patient_id as string) like 'PAYORMBR:%' or identity_id like 'PAYORMBR:%'

union all
select 'int_finraf__payor_paid_actuals', patient_id
from {{ ref('int_finraf__payor_paid_actuals') }}
where patient_id like 'PAYORMBR:%' or identity_id like 'PAYORMBR:%'

union all
select 'int_spend__member_month', patient_id
from {{ ref('int_spend__member_month') }}
where patient_id like 'PAYORMBR:%' or identity_id like 'PAYORMBR:%'

union all
select 'int_spend__claims_detail', patient_id
from {{ ref('int_spend__claims_detail') }}
where patient_id like 'PAYORMBR:%' or identity_id like 'PAYORMBR:%'

union all
select 'mart_payor_unmatched_members', identity_id
from {{ ref('mart_payor_unmatched_members') }}
where identity_id like 'PAYORMBR:%'
