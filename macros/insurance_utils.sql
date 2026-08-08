{% macro is_original_medicare(product_type_column, govt_funded_column=none) %}
    {#
        Check if insurance is Original Medicare (fee-for-service).
        Aligned with insurance_plans dimension logic.
        When govt_funded_column is available, uses it as authoritative source.
        Falls back to product_type pattern matching when only product_type is available.
    #}
    (
        {% if govt_funded_column %}
            {{ govt_funded_column }} = 'Medicare'
            or {{ product_type_column }} = 'Medicare B-Traditional'
        {% else %}
            {{ product_type_column }} = 'Medicare B-Traditional'
            or ({{ product_type_column }} like 'Medicare%'
                and {{ product_type_column }} not in ('Medicare PPO', 'Medicare HMO', 'Medicare Private FFS', 'Medicare Supplemental Plan')
                and {{ product_type_column }} not like '%Medicaid%')
        {% endif %}
    )
{% endmacro %}


{% macro is_medicare_advantage(product_type_column, govt_funded_column=none) %}
    {#
        Check if insurance is Medicare Advantage (managed Medicare).
        Aligned with insurance_plans dimension logic.
        When govt_funded_column is available, uses it as authoritative source.
    #}
    (
        {% if govt_funded_column %}
            {{ govt_funded_column }} = 'Medicare Replacement/Advantage'
        {% else %}
            {{ product_type_column }} in ('Medicare PPO', 'Medicare HMO', 'Medicare Private FFS')
        {% endif %}
    )
{% endmacro %}


{% macro is_medigap(product_type_column) %}
    {#
        Check if insurance is a Medicare Supplement (Medigap) plan.
        Medigap patients have Medicare Part B as primary (seq 1).
        For payor_category purposes, Medigap rolls into Original Medicare.
    #}
    {{ product_type_column }} = 'Medicare Supplemental Plan'
{% endmacro %}


{% macro is_medicare_any(product_type_column, govt_funded_column=none) %}
    {#
        Check if insurance is any Medicare-related type:
        Original Medicare, Medicare Advantage, or Medicare Supplement.
    #}
    (
        {% if govt_funded_column %}
            {{ govt_funded_column }} in ('Medicare', 'Medicare Replacement/Advantage')
            or {{ product_type_column }} in ('Medicare B-Traditional', 'Medicare Supplemental Plan')
        {% else %}
            {{ product_type_column }} like 'Medicare%'
            and {{ product_type_column }} not like '%Medicaid%'
        {% endif %}
    )
{% endmacro %}


{% macro is_medicaid(product_type_column, govt_funded_column=none) %}
    {#
        Check if insurance is Medicaid.
        Aligned with insurance_plans dimension logic.
    #}
    (
        {% if govt_funded_column %}
            {{ govt_funded_column }} in ('Medicaid', 'Medicaid Replacement')
            or {{ product_type_column }} like '%Medicaid%'
        {% else %}
            {{ product_type_column }} like '%Medicaid%'
        {% endif %}
    )
{% endmacro %}


{% macro is_commercial(product_type_column, govt_funded_column=none) %}
    {#
        Check if insurance is Commercial.
        Commercial = NOT Medicare (any) and NOT Medicaid and NOT Self-Pay.
        Aligned with insurance_plans dimension logic.
    #}
    (
        not {{ is_medicare_any(product_type_column, govt_funded_column) }}
        and not {{ is_medicaid(product_type_column, govt_funded_column) }}
        and {{ product_type_column }} not like '%Self%Pay%'
    )
{% endmacro %}


{% macro insurance_category(product_type_column, govt_funded_column=none) %}
    {#
        Categorize insurance into 6 payor categories.
        Produces the same values as insurance_plans.payor_category.
        Medigap is its own category (almost always secondary insurance).
    #}
    case
        when {{ is_medicare_advantage(product_type_column, govt_funded_column) }} then 'Medicare Advantage'
        when {{ is_original_medicare(product_type_column, govt_funded_column) }} then 'Original Medicare'
        when {{ is_medigap(product_type_column) }} then 'Medicare Supplement'
        when {{ is_medicaid(product_type_column, govt_funded_column) }} then 'Medicaid'
        when {{ product_type_column }} like '%Self%Pay%' then 'Self-Pay'
        else 'Commercial'
    end
{% endmacro %}

