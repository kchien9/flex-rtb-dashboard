-- Closed Won, by Rep -- the drill-down underneath "Closed Won, by Team" on the Deals & Units
-- page. Per Kevin: "would be nice if you click into each team the rep names appeared and u
-- can see how they trend vs last month." Same team_bucket mapping and same New Logo/
-- Expansion/Move In deal-type scope as performance_cube.sql, just grouped one level deeper
-- (rep instead of team). Validated live 2026-07-28: Dana's Team's team-level number is not
-- evenly spread -- Cory Baach alone dropped from 62,667 to 12,490 while Evan Klein, Doron
-- David, and Ariel Kurek moved less dramatically. Confirms the same "the team average hides
-- who's actually driving it" pattern already established elsewhere in this repo
-- (insights_driver_concentration.sql).
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.

WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label)) AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE()) AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_month_full',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day, 3, DATEADD(month, -1, bp_month_label))
    FROM current_bp
)
SELECT
    e.FULL_NAME AS rep,
    CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
        ELSE NULL
    END AS team_bucket,
    SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN p1.start_date AND p1.end_date, o.FLEX_UNIT_COUNT, 0)) AS units_this_month,
    SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN p2.start_date AND p2.end_date, o.FLEX_UNIT_COUNT, 0)) AS units_last_month
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
JOIN bp_periods p1 ON p1.period = 'this_month'
JOIN bp_periods p2 ON p2.period = 'last_month_full'
WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
GROUP BY 1, 2
HAVING (units_this_month > 0 OR units_last_month > 0)
  {{#Team.value}} AND CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
        ELSE NULL
    END = '{{Team.value}}' {{/Team.value}}
ORDER BY units_this_month DESC;
