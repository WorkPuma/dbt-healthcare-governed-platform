{% macro source_updated_at_filter(column='source_updated_at', lookback_hours=24) %}
{#
    Incremental filter using source-system timestamps for CDF-accurate change detection.

    Usage in any incremental merge model:
      SELECT ...
        GREATEST(a.lastupdated, ...) AS source_updated_at
      FROM {{ source('athenahealth', 'appointment') }} a
      {{ source_updated_at_filter('source_updated_at') }}

    What it does:
      - On first run (or --full-refresh): no filter, processes everything
      - On incremental run: only rows where the source timestamp exceeds the
        max already in the target table, with a safety lookback window

    Why this matters for CDF:
      Source timestamps (lastupdated, SystemModstamp, last_updated_at) are set by
      the origin system and only change when real data changes. Combined with
      matched_condition in the model config, this ensures Delta CDF only records
      genuinely modified rows — eliminating false updates that cascade through
      ServingDB and cause Cube pre-aggregation timeouts.

    Pair with this config block:
      {{ config(
          ...
          target_alias='t',
          source_alias='s',
          matched_condition='t.source_updated_at < s.source_updated_at',
      ) }}

    The lookback_hours parameter (default 24) adds a safety buffer so
    late-arriving rows from the source aren't missed.
#}
{% if is_incremental() %}
WHERE {{ column }} >= (
    SELECT DATEADD(
        HOUR,
        -{{ lookback_hours }},
        COALESCE(MAX({{ column }}), TIMESTAMP '1900-01-01')
    )
    FROM {{ this }}
)
{% endif %}
{% endmacro %}
