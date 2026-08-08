-- Fan-out / loop firewall for the self-service report builder.
--
-- The mart_relationships seed declares safe many_to_one / one_to_one edges
-- between marts. A future single-hop join feature (and the drill-through
-- navigation shipping now) must never be able to follow a cycle
-- (A -> B -> A) and explode. This singular test fails the dbt build if the
-- curated edge set contains any directed cycle.
--
-- Implementation: walk the directed graph (from_mart -> to_mart) with a
-- recursive CTE, carrying the visited path. If we ever revisit a node that
-- is already on the path, that's a cycle -> return the offending rows ->
-- dbt test fails.

-- NOTE: `recursive` keyword is required by Spark/Databricks SQL for the
-- self-referencing `walk` CTE below; it applies to the whole WITH list, the
-- non-recursive `edges` CTE is allowed alongside it.
--
-- static_analysis='off': the dbt Fusion static analyzer cannot parse Spark's
-- `with recursive` (raises SyntaxInvalid dbt0101), but the query is valid on
-- Databricks and executes/passes there. Disable static typechecking for this
-- one test so the recursive firewall keeps running clean.
{{ config(static_analysis='off') }}

with recursive edges as (
    select distinct from_mart, to_mart
    from {{ ref('mart_relationships') }}
    where from_mart is not null
      and to_mart is not null
),

walk as (
    -- seed: each edge starts its own path
    select
        from_mart                                  as origin,
        to_mart                                    as current_node,
        array(from_mart, to_mart)                  as path,
        case when from_mart = to_mart then true else false end as is_cycle
    from edges

    union all

    -- extend each path by one hop; flag a cycle when the next node is
    -- already on the path
    select
        w.origin,
        e.to_mart                                  as current_node,
        array_append(w.path, e.to_mart)            as path,
        array_contains(w.path, e.to_mart)          as is_cycle
    from walk w
    join edges e
        on e.from_mart = w.current_node
    -- stop recursing once a cycle is found, and bound depth defensively
    where w.is_cycle = false
      and size(w.path) < 50
)

select origin, current_node, path
from walk
where is_cycle = true
