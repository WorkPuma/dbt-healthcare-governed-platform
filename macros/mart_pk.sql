{% macro mart_pk(natural_key_columns) -%}
    {#-
        Surrogate hash PK for marts that will be replicated into ServingDB.

        Why this exists:
          ServingDB managed sync MERGEs incoming rows by the synced table's
          primary key. When the PK is a composite of nullable columns,
          Postgres treats NULL ≠ NULL — multiple rows that *should* be
          distinct collide under the MERGE, and silently get deduped on
          the Postgres side. The result: the synced table can hold ~50%
          of the source row count with no error surfaced.

          A single, non-NULL md5 hash over the natural key eliminates the
          problem entirely. ServingDB MERGE keys cleanly, every source row
          survives the sync, and CDF tracks individual row changes
          correctly.

        Use this macro in every dbt model that has
        `meta.servingdb_sync: true`. The model's `unique_key` config must
        reference the surrogate column the macro emits (`<model>_id`).

        Usage:
          select
            {{ mart_pk(['period_start', 'npv_category', 'is_membership_patient']) }} as mart_npv_weekly_id,
            ...

        The macro:
          - casts every column to string,
          - coalesces strings to empty and bools to 'false' so NULLs are
            disambiguated from real values (foo|NULL|bar vs foo||bar
            collide; foo|false|bar vs foo|true|bar do not),
          - joins with a pipe separator,
          - md5s the result.
    -#}
    md5(concat_ws(
        '|',
        {%- for col in natural_key_columns -%}
        coalesce(cast({{ col }} as string), '')
        {%- if not loop.last -%}, {% endif %}
        {%- endfor -%}
    ))
{%- endmacro %}
