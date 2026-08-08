{{
    config(
        tags=['athenahealth', 'qmresult', 'base']
    )
}}

/*
    Base passthrough for the raw athenahealth.athenaone.QMRESULT Delta table.

    This is the ONLY model that reads the raw QMRESULT source. It is a pure
    1:1 passthrough -- no filter, no rename -- shared by BOTH consumers that
    otherwise independently read this physical table:
      - the quality funnel (stg_athena__qmresult), which applies the
        isdeleted/isarchived delete filter itself
      - provider_bonus (stg_bonus__quality_measures), which reads deletes
        included today

    Per DEV-4296 shared-staging decision (PR #346 review, Data Engineer):
    "extract shared staging ... keep consumer-specific filters in
    int_quality__*". Delete filtering is intentionally NOT applied here --
    doing so here would silently change provider_bonus's numbers. See
    REDACTED_PATH
*/

select
    p4presultid,
    patientid,
    chartid,
    providerid,
    contextid,
    p4pprogram,
    p4pmeasure,
    resultstatus,
    satisfieddate,
    exclusionreason,
    lastupdated,
    isdeleted,
    isarchived
from {{ source('athenahealth_metadata', 'qmresult') }}
