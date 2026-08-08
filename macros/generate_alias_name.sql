{% macro generate_alias_name(custom_alias_name=none, node=none) -%}
    {#-
        Alias-name generation for GenericCo Analytics.

        Mirrors the allow-list in `generate_schema_name`:

          - PROD targets (`prod`, `prod_jobs`) → real table name (no rewriting).
          - DEV  targets (`dev`, `devcg`)      → real table name as well. Dev
                                                  isolation is by CATALOG
                                                  (databricks_dev), so dev tables
                                                  keep their canonical names. The
                                                  old `dev<INITIALS>_` prefix
                                                  scheme (PR #173 ghost tables)
                                                  is retired.
          - Anything else                      → fail loudly so a misconfigured
                                                  target (e.g. dbt Cloud
                                                  `default`) can never write into
                                                  the wrong catalog.

        Combined with generate_schema_name + generate_database_name, a DEV
        target always produces:  databricks_dev.<schema>.<table>
    -#}

    {%- set prod_targets = ['prod', 'prod_jobs'] -%}
    {%- set dev_targets = ['dev', 'devcg'] -%}
    {%- set raw = (custom_alias_name | trim) if custom_alias_name else node.name -%}

    {%- if target.name in prod_targets or target.name in dev_targets -%}
        {{ raw }}
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "generate_alias_name: unknown target '" ~ target.name ~ "'. "
            ~ "Configure --target prod, prod_jobs, or dev. "
            ~ "dbt Cloud users: set Credentials > target_name = prod (NOT 'default') "
            ~ "or this run would write into the wrong catalog."
        ) }}
    {%- endif -%}

{%- endmacro %}
