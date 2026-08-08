{% macro generate_schema_name(custom_schema_name, node) -%}
    {#-
        Schema-name generation for GenericCo Analytics.

        Targets fall into exactly two buckets:

          1. PROD targets — `prod`, `prod_jobs`
             Writes go to the real prod schemas in databricks_prod; no rewriting.

          2. DEV targets  — `dev` (and its back-compat alias `devcg`)
             Dev/prod separation is now by CATALOG, not by name prefix: the dev
             targets point at the `databricks_dev` catalog (a deep-clone mirror
             of prod, refreshed by databricks_dev_catalog_clone.py). Because the
             whole catalog is isolated, dev relations keep their REAL schema and
             table names — no `dev<INITIALS>_` prefix. The old prefix-in-prod
             scheme (which produced the `devcg_*` ghost tables, PR #173) is
             retired.

        Any other target value (e.g. dbt Cloud's `default`, an unconfigured
        local run, a typo) is a misconfiguration and we fail loudly rather
        than silently writing into the wrong catalog/schema.
    -#}

    {%- set prod_targets = ['prod', 'prod_jobs'] -%}
    {%- set dev_targets = ['dev', 'devcg'] -%}
    {%- set base = (custom_schema_name | trim) if custom_schema_name else target.schema -%}

    {#-
        dbt Cloud CI / PR-validation runs (Slim CI).
        CircleCI triggers the CI job (slim-ci) with
        schema_override = dbt_cloud_pr_<job_id>_<pr_number> and
        non_native_pull_request_id (Bitbucket has no native PR webhook, so
        DBT_CLOUD_PR_ID is never set — schema_override is the deterministic
        signal). dbt exposes the override as target.schema. We MUST isolate
        every model into that PR schema so `dbt build --select state:modified+`
        on a PR can never CREATE OR REPLACE / MERGE into a real prod schema
        (healthcare, marts_bi_v3, mdm.reference_data, ...). state defer reads
        unchanged upstream models from prod; only modified models build here.

        This branch is INERT for prod / prod_jobs / devcg / local runs because
        their target.schema is 'dbt_prod' (never starts with 'dbt_cloud_pr').
    -#}
    {%- if (target.schema | lower).startswith('dbt_cloud_pr') -%}
        {%- if custom_schema_name -%}
            {{ target.schema ~ '_' ~ base }}
        {%- else -%}
            {{ target.schema }}
        {%- endif -%}
    {%- elif target.name in prod_targets or target.name in dev_targets -%}
        {#- Catalog isolation handles dev/prod separation; real schema name either way. -#}
        {{ base }}
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "generate_schema_name: unknown target '" ~ target.name ~ "'. "
            ~ "Configure --target prod, prod_jobs, or dev. "
            ~ "dbt Cloud users: set Credentials > target_name = prod (NOT 'default') "
            ~ "or this run would write into the wrong catalog."
        ) }}
    {%- endif -%}

{%- endmacro %}
