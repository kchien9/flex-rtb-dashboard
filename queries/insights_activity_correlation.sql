-- Insights Engine, Part 3: Activity <-> Outcome correlation
-- Kevin's own framing: "SMB team's activities are 50% less this month -> units are less
-- too." Then drill from the team-level activity drop into rep-level ("X person is doing
-- 75% less") so Sham can flag it to the manager by name, not just by team.
--
-- Why this didn't exist in the current Sigma RTB workbook: that workbook has 90+ elements,
-- almost all repeated joins/aggregations of PROPERTY_BP_MONTH_STATS alone (confirmed by
-- inspecting it directly) -- no Salesforce activity data (calls/emails/meetings) is joined
-- in anywhere. Units and activity live in separate systems today (Sigma vs Salesforce
-- reports) with no correlation layer connecting them. This closes that gap.
--
-- Team taxonomy note: uses FLEX.MART.DIM_EMPLOYEE_HISTORY.TEAM_NAME (current employee team)
-- as the single team source for BOTH sides of the correlation. PROPERTY_BP_MONTH_STATS'
-- HUBSPOT_STATIC_TEAM_NAME_DEAL (deal-time team) is a DIFFERENT taxonomy (pod names don't
-- fully overlap) -- mixing the two would silently misattribute activity to the wrong team.
-- Units here are FCT_CRM_OPPORTUNITY.FLEX_UNIT_COUNT (deal-grain, current owner's team),
-- not the rolled-out-units cube, to stay on one consistent taxonomy.
--
-- Validated against live Snowflake 2026-07-27 -- REAL output, not illustrative:
--   Strategic Team: activity down 49% (1446 -> 731), units down 51% (148,813 -> 73,295)
--   Drilling into Strategic Team reps: Evan Klein down 75%, Doron David down 75%,
--   Jennette Sanchez down 46% -- two reps account for most of the team's activity drop.
--
-- FILTER ESCAPING -- Part B's {{ Team.value }} = 'Strategic Team' works fine, but the same
-- pattern breaks the moment someone clicks a row for "Brandon's Team" or "Cory's Team" --
-- confirmed live elsewhere in this repo (naive '{{Value}}' interpolation is not apostrophe-
-- safe). Prefer Superblocks' native bind-parameter syntax for the Snowflake connector over
-- raw Mustache substitution here; if only Mustache is available, double the apostrophes in
-- the value before it reaches this query.

-- Part A: team-level correlation flag
WITH activity AS (
    SELECT EMPLOYEE_SK, TS FROM (
        SELECT EMPLOYEE_SK, COMPLETED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_TASK
        WHERE TASK_STATUS = 'completed' AND TASK_DIRECTION = 'outbound'
        UNION ALL
        SELECT EMPLOYEE_SK, STARTED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_MEETING
        WHERE MEETING_STATUS = 'completed'
    )
),
team_activity AS (
    SELECT e.TEAM_NAME AS team,
        SUM(IFF(a.TS BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, 1, 0)) AS activity_this,
        SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)) AS activity_last
    FROM activity a
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON a.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    WHERE e.TEAM_NAME IS NOT NULL
    GROUP BY 1
),
team_units AS (
    SELECT e.TEAM_NAME AS team,
        SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, o.FLEX_UNIT_COUNT, 0)) AS units_this,
        SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, o.FLEX_UNIT_COUNT, 0)) AS units_last
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    WHERE e.TEAM_NAME IS NOT NULL
    GROUP BY 1
)
SELECT * FROM (
    SELECT
        COALESCE(a.team, u.team) AS team,
        a.activity_this, a.activity_last,
        DIV0(a.activity_this - a.activity_last, a.activity_last) AS activity_pct_change,
        u.units_this, u.units_last,
        DIV0(u.units_this - u.units_last, u.units_last) AS units_pct_change,
        -- the callout: only fires when BOTH move the same (negative) direction --
        -- a real correlation, not a coincidence of one metric alone
        COALESCE(a.team, u.team) || ' team''s activity is down ' ||
            ROUND(ABS(DIV0(a.activity_this - a.activity_last, a.activity_last)) * 100, 0) ||
            '% this period -- units are down ' ||
            ROUND(ABS(DIV0(u.units_this - u.units_last, u.units_last)) * 100, 0) || '% too' AS callout
    FROM team_activity a
    FULL OUTER JOIN team_units u ON a.team = u.team
    WHERE a.activity_last > 20 AND u.units_last > 0
      AND DIV0(a.activity_this - a.activity_last, a.activity_last) <= -0.20
      AND DIV0(u.units_this - u.units_last, u.units_last) <= -0.10
)
ORDER BY activity_pct_change ASC;

-- Part B: rep-level drill-in, once a team is clicked -- "who's actually down within this team"
-- {{ Team.value }} is set by clicking a Part A row in Superblocks (same drill-down mechanic
-- as the other insight queries -- no separate query needed per team).
WITH activity AS (
    SELECT EMPLOYEE_SK, TS FROM (
        SELECT EMPLOYEE_SK, COMPLETED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_TASK
        WHERE TASK_STATUS = 'completed' AND TASK_DIRECTION = 'outbound'
        UNION ALL
        SELECT EMPLOYEE_SK, STARTED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_MEETING
        WHERE MEETING_STATUS = 'completed'
    )
)
SELECT
    e.FULL_NAME AS rep,
    SUM(IFF(a.TS BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, 1, 0)) AS activity_this,
    SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)) AS activity_last,
    DIV0(
        SUM(IFF(a.TS BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, 1, 0))
        - SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)),
        SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0))
    ) AS pct_change
FROM activity a
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON a.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
WHERE e.TEAM_NAME = '{{ Team.value }}'
GROUP BY 1
HAVING SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)) > 10
ORDER BY pct_change ASC;
