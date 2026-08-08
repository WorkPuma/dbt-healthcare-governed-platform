{{
    config(
        tags=['athenahealth', 'p4pmeasure', 'base']
    )
}}

/*
    Base passthrough for the raw athenahealth.athenaone.P4PMEASURE Delta
    table.

    This is the ONLY model that reads the raw P4PMEASURE source. Pure 1:1
    passthrough -- no filter, no rename -- shared by BOTH the quality funnel
    (stg_athena__p4pmeasure, which drops deleteddatetime is not null itself)
    and provider_bonus (stg_bonus__quality_measures, inline reader).

    Per DEV-4296 shared-staging decision (PR #346 review, Data Engineer): one
    shared source read, consumer-specific filters stay downstream. See
    REDACTED_PATH
*/

select
    p4pmeasureid,
    category,
    shortname,
    measuretype,
    name,
    deleteddatetime
from {{ source('athenahealth', 'p4pmeasure') }}
