{{
    config(
        tags=['athenahealth', 'p4presult', 'base']
    )
}}

/*
    Base passthrough for the raw athenahealth.athenaone.P4PRESULT Delta table.

    This is the ONLY model that reads the raw P4PRESULT source. Pure 1:1
    passthrough -- no filter, no rename -- shared by BOTH the quality funnel
    (stg_athena__p4presult, which drops deleteddatetime is not null itself)
    and provider_bonus (stg_bonus__quality_measures, inline reader).

    Per DEV-4296 shared-staging decision (PR #346 review, Data Engineer): one
    shared source read, consumer-specific filters stay in int_quality__* /
    the bonus model. See
    REDACTED_PATH
*/

select
    p4presultid,
    p4pmeasureid,
    patientid,
    deleteddatetime
from {{ source('athenahealth', 'p4presult') }}
