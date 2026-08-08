{% macro scd2_current_filter(relation, alias=none) %}
{#
    Backwards-compatible "current version only" predicate for Lakeflow Connect
    (Databricks native Salesforce sync) streaming tables.

    WHY THIS EXISTS
    ---------------
    When change tracking (SCD Type 2) is enabled on a Lakeflow Connect table, the
    connector rebuilds the table with __START_AT / __END_AT columns and emits one
    row per historical version of each record. The current row is the one where
    __END_AT IS NULL. Reading the table directly without that predicate fans out
    every downstream join and breaks uniqueness tests — exactly what happened when
    change tracking was first turned on for salesforce.account (2.1M version rows
    for 21.5K distinct Ids). See the canonical predicate added in DEV-4363.

    WHAT IT DOES
    ------------
    Emits `<alias>.__END_AT is null` ONLY when the relation actually has an
    __END_AT column. If the table has not had change tracking enabled yet
    (still SCD Type 1, one row per Id) the macro emits `true`, so the query
    forwards every row exactly as it does today — no behavior change until the
    connector is flipped. This lets the dbt change deploy safely BEFORE the
    Lakeflow Connect pipeline is switched to SCD Type 2, and keeps every model
    correct on both sides of the flip with no further edits.

    USAGE — base passthrough model (the canonical pattern; see
    base_salesforce__appointment / base_salesforce__attribution). Every
    downstream model reads the base ref(), never the raw source, so the
    versioning is caught one layer below and no consumer has to change:
        select *
        from {{ source('salesforce', 'appointment__c') }}
        where {{ scd2_current_filter(source('salesforce', 'appointment__c')) }}

    USAGE — inline in a model WHERE with an alias:
        from {{ ref('base_salesforce__appointment') }} appt
        where appt.IsDeleted = false
          and {{ scd2_current_filter(source('salesforce', 'appointment__c'), 'appt') }}

    NOTE: do NOT put this in a source-level test `where:` config — dbt-fusion's
    typed schema parser rejects Jinja there. Assert uniqueness on the base model
    instead (current-row grain), which is where it belongs.
#}
    {%- set prefix = (alias ~ '.') if alias else '' -%}
    {%- if not execute -%}
        {#- parse-time: no relation introspection, emit a no-op predicate -#}
        true
    {%- else -%}
        {%- set col_names = adapter.get_columns_in_relation(relation)
              | map(attribute='name') | map('lower') | list -%}
        {%- if '__end_at' in col_names -%}
            {{ prefix }}__END_AT is null
        {%- else -%}
            true
        {%- endif -%}
    {%- endif -%}
{% endmacro %}
