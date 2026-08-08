{% macro smart_incremental_filter(timestamp_column, lookback_hours=6) %}
{#
    Self-documenting incremental filter for merge-strategy models.

    Usage in any model:
      {{ config(
          materialized='incremental',
          incremental_strategy='merge',
          unique_key='appointment_id',
          on_schema_change='sync_all_columns'
      ) }}

      SELECT ... FROM {{ ref('upstream') }}
      {{ smart_incremental_filter('refresh_timestamp') }}

    What it does:
      - On first run (or --full-refresh): no filter, processes everything
      - On incremental run: only rows where timestamp_column > max in target,
        with a safety lookback window to catch late-arriving data

    The lookback_hours parameter (default 6) adds a safety buffer so
    late-arriving rows from the source aren't missed.
#}
{% if is_incremental() %}
WHERE {{ timestamp_column }} >= (
    SELECT DATEADD(HOUR, -{{ lookback_hours }}, MAX({{ timestamp_column }}))
    FROM {{ this }}
)
{% endif %}
{% endmacro %}
