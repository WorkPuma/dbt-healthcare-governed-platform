/*
  DEV-4535: when the identity profile has a governed primary Athena id,
  int_empi__payor_identity_spine.athena_patient_id must match it.
*/

{{ config(severity='error', tags=['empi', 'identity', 'integrity']) }}

with profile_primary as (
    select
        identity_id,
        coalesce(
            primary_athena_id_herself_health,
            primary_athena_id_midi
        ) as governed_athena_patient_id
    from {{ source('healthcare', 'empi_identity_profile') }}
    where identity_id is not null
      and coalesce(
            primary_athena_id_herself_health,
            primary_athena_id_midi
          ) is not null
)

select
    s.payor,
    s.payor_member_id,
    s.identity_id,
    s.athena_patient_id as spine_athena_patient_id,
    p.governed_athena_patient_id as profile_primary_athena_id
from {{ ref('int_empi__payor_identity_spine') }} s
inner join profile_primary p
    on p.identity_id = s.identity_id
where s.athena_patient_id is distinct from p.governed_athena_patient_id
