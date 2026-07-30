-- DEPRECATED 2026-07-30 -- Kevin: "i think this activity to outcome table can be deprecated
-- bc we cant really create a causal chain." This file's whole framing (the callout literally
-- says "activity is down X% -- units are down Y% too") IS the causal narrative Kevin is
-- pulling back from -- checked directly, the underlying correlation is too weak/inconsistent
-- to support it. Replaced by full_funnel_by_segment.sql / activities_by_team.sql /
-- activity_vs_outcome_by_rep.sql -- same numbers, side by side, no "X caused Y" callout text.
-- Leave in place until Superblocks unwires it, then delete.
--
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
-- Units here are FCT_CRM_OPPORTUNITY.FLEX_UNIT_COUNT (deal-grain, current owner's team), not
-- the rolled-out-units cube, to stay on one consistent taxonomy.
--
-- Validated against live Snowflake 2026-07-27 -- REAL output, not illustrative:
--   Strategic Team: activity down 49% (1446 -> 731), units down 51% (148,813 -> 73,295)
--   Drilling into Strategic Team reps: Evan Klein down 75%, Doron David down 75%,
--   Jennette Sanchez down 46% -- two reps account for most of the team's activity drop.
--
-- REBUILT 2026-07-29 -- two fixes, per Kevin's sweeping "dont just fix this in this query it
-- needs to be fixed everywhere. i dont want to see inactive or users on entirely diff teams
-- in any table":
--   1. TEAM_BUCKET, NOT RAW TEAM_NAME -- this file previously grouped by raw
--      DIM_EMPLOYEE_HISTORY.TEAM_NAME directly, which meant it never collapsed the stale
--      Cory's Team/Heidi's Team labels into Dana's Team the way every other query in this
--      repo does, and Part B's {{ Team.value }} filter had to match a raw pod name instead of
--      the clean team_bucket value the rest of the app uses. Both parts now use the same
--      team_map pattern as activity_vs_outcome_by_rep.sql.
--   2. INACTIVE/CROSS-TEAM LEAKAGE FIX -- same root cause as everywhere else in this repo:
--      DIM_EMPLOYEE_HISTORY has no active/inactive concept and carries multiple IS_CURRENT
--      rows per person across source systems. team_map dedupes to the Salesforce-sourced row,
--      joins deduped STG_SALESFORCE__USER for real TEAM_NAME/PARENT_TEAM/IS_ACTIVE/
--      LAST_LOGIN_AT_UTC (PARENT_TEAM='Mid Market +' required for the Strategic pod, drops
--      Saba Obaid-style stray records), and applies the standard {{ GraceMonths.value }}
--      (default 2) departure grace period.
--
-- FILTER ESCAPING -- Part B's {{ Team.value }} now matches a team_bucket value ("Dana's
-- Team"), which still contains an apostrophe -- the same escaping risk as every value filter
-- in this repo applies. Prefer Superblocks' native bind-parameter syntax for the Snowflake
-- connector over raw Mustache substitution; if only Mustache is available, double the
-- apostrophe before it reaches this query.

-- Part A: team-level correlation flag
WITH emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
team_map AS (
    SELECT ed.EMPLOYEE_SK, u.FULL_NAME,
        CASE
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
activity AS (
    SELECT EMPLOYEE_SK, TS FROM (
        SELECT EMPLOYEE_SK, COMPLETED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_TASK
        WHERE TASK_STATUS = 'completed' AND TASK_DIRECTION = 'outbound'
        UNION ALL
        SELECT EMPLOYEE_SK, STARTED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_MEETING
        WHERE MEETING_STATUS = 'completed'
    )
),
team_activity AS (
    SELECT m.team_bucket AS team,
        SUM(IFF(a.TS BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, 1, 0)) AS activity_this,
        SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)) AS activity_last
    FROM activity a
    JOIN team_map m ON a.EMPLOYEE_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    GROUP BY 1
),
team_units AS (
    SELECT m.team_bucket AS team,
        SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, o.FLEX_UNIT_COUNT, 0)) AS units_this,
        SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, o.FLEX_UNIT_COUNT, 0)) AS units_last
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    JOIN team_map m ON o.OWNER_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
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
-- as the other insight queries -- no separate query needed per team). Value is now a
-- team_bucket ("Dana's Team"), matching Part A's output column.
WITH emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
team_map AS (
    SELECT ed.EMPLOYEE_SK, u.FULL_NAME,
        CASE
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
activity AS (
    SELECT EMPLOYEE_SK, TS FROM (
        SELECT EMPLOYEE_SK, COMPLETED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_TASK
        WHERE TASK_STATUS = 'completed' AND TASK_DIRECTION = 'outbound'
        UNION ALL
        SELECT EMPLOYEE_SK, STARTED_AT_UTC AS TS FROM FLEX.SALES.FCT_CRM_MEETING
        WHERE MEETING_STATUS = 'completed'
    )
)
SELECT
    m.FULL_NAME AS rep,
    SUM(IFF(a.TS BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, 1, 0)) AS activity_this,
    SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)) AS activity_last,
    DIV0(
        SUM(IFF(a.TS BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}, 1, 0))
        - SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)),
        SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0))
    ) AS pct_change
FROM activity a
JOIN team_map m ON a.EMPLOYEE_SK = m.EMPLOYEE_SK
WHERE m.team_bucket = '{{ Team.value }}'
GROUP BY 1
HAVING SUM(IFF(a.TS BETWEEN {{ LastPeriodStart }} AND {{ LastPeriodEnd }}, 1, 0)) > 10
ORDER BY pct_change ASC;
