{% macro generate_database_name(custom_database_name=none, node=none) -%}
    {#-
        Database (catalog) routing for GenericCo Analytics — the third leg of the
        dev/prod separation alongside generate_schema_name + generate_alias_name.

          - PROD targets (`prod`, `prod_jobs`):
              Honor an explicit +database (e.g. the mdm models -> `mdm`),
              otherwise the profile catalog (`databricks_prod`). Same as dbt's
              default behavior.

          - DEV targets (`dev`, `devcg`):
              Force EVERY model into the dev catalog (`databricks_dev`, the
              profile's `catalog:`), overriding any +database. This keeps dev
              MDM builds (+database: mdm) out of the shared `mdm` catalog and
              aligned with the deep-cloned databricks_dev.reference_data.

          - dbt Cloud Slim-CI (target.schema starts with `dbt_cloud_pr`):
              Force EVERY model into the default profile catalog
              (`databricks_prod`), overriding any +database. generate_schema_name
              isolates the write into a throwaway per-PR schema, but that only
              works in a catalog dbt can CREATE SCHEMA in. An external +database
              catalog (e.g. `mdm`) has no per-PR schema, so honoring +database
              here produces `mdm.dbt_cloud_pr_<id>_reference_data` ->
              SCHEMA_NOT_FOUND when a +database model lands in state:modified+
              (PR #218: the mdm sync models). Routing to target.database keeps the
              isolated PR copy in databricks_prod.<pr_schema>_reference_data, which
              dbt creates like every other PR-isolated model.

        generate_schema_name fails loudly on any other target, so an unknown
        target can never reach a real-catalog write through this macro.
    -#}
    {%- set dev_targets = ['dev', 'devcg'] -%}
    {%- if target.name in dev_targets -%}
        {{ target.database }}
    {%- elif (target.schema | lower).startswith('dbt_cloud_pr') -%}
        {{ target.database }}
    {%- else -%}
        {{ custom_database_name if custom_database_name else target.database }}
    {%- endif -%}
{%- endmacro %}
