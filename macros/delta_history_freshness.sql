{% macro delta_history_freshness(database, schema, table) %}
{#
    Returns a SQL query for dbt source freshness that checks the Delta Lake
    transaction log instead of requiring a loaded_at column in the data.

    Used via loaded_at_query in _sources.yml for Delta tables that don't have
    a _fivetran_synced or loaded_at column (e.g., athenahealth replicas).

    The DESCRIBE HISTORY command returns the timestamp of the last write
    operation, which is the most accurate indicator of data freshness.
#}
SELECT MAX(timestamp) as max_loaded_at FROM (DESCRIBE HISTORY {{ database }}.{{ schema }}.{{ table }} LIMIT 1)
{% endmacro %}
