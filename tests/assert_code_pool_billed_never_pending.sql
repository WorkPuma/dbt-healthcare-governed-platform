select
    patient_id,
    code,
    code_type,
    date_of_service
from {{ ref('int_quality__code_pool') }}
where evidence_provenance = 'billed'
  and order_status = 'pending'
