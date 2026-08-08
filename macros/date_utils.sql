{% macro days_between(start_date, end_date) %}
    {#
        Calculate days between two dates.
        Handles null values gracefully.
    #}
    case 
        when {{ start_date }} is null or {{ end_date }} is null then null
        else datediff(day, {{ start_date }}, {{ end_date }})
    end
{% endmacro %}


{% macro is_within_days(date_column, days) %}
    {#
        Check if a date is within N days of today.
    #}
    {{ date_column }} >= dateadd(day, -{{ days }}, current_date())
{% endmacro %}


{% macro fiscal_year(date_column) %}
    {#
        Get fiscal year from date.
        Assumes fiscal year starts in January.
    #}
    year({{ date_column }})
{% endmacro %}


{% macro age_in_years(birth_date) %}
    {#
        Calculate age in years from birth date.
    #}
    case 
        when {{ birth_date }} is null then null
        else floor(datediff(day, {{ birth_date }}, current_date()) / 365.25)
    end
{% endmacro %}

