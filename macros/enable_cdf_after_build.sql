{% macro enable_cdf_after_build() %}
  {#
    Safety-net on-run-end hook: re-enables CDF on table-materialized models
    only.  Incremental (merge) models preserve tblproperties across MERGE INTO,
    so the ALTER is a wasted DDL call.  The only scenario where CDF is lost is
    CREATE OR REPLACE TABLE (table materialization or --full-refresh on an
    incremental), and dbt_project.yml's +tblproperties already handles that at
    CREATE time.  This hook is a belt-and-suspenders safety net for ServingDB
    TRIGGERED sync which hard-requires CDF on every source table.
  #}
  {% if execute %}
    {% set ns = namespace(count=0) %}
    {% for result in results %}
      {% if result.status == 'success'
         and result.node.resource_type == 'model'
         and result.node.config.materialized == 'table' %}
        {% set fqn = result.node.database ~ '.' ~ result.node.schema ~ '.' ~ result.node.alias %}
        {% set alter_sql %}
          ALTER TABLE {{ fqn }} SET TBLPROPERTIES (delta.enableChangeDataFeed = true)
        {% endset %}
        {{ log("enable_cdf_after_build: ensuring CDF on table model " ~ fqn, info=True) }}
        {% do run_query(alter_sql) %}
        {% set ns.count = ns.count + 1 %}
      {% endif %}
    {% endfor %}
    {{ log("enable_cdf_after_build: processed " ~ ns.count ~ " table-materialized model(s) (incremental models skipped — CDF survives MERGE)", info=True) }}
  {% endif %}
{% endmacro %}
