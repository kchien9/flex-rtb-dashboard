-- Activity vs. Outcome, by Rep -- the deeper Activities-tab build-out Kevin asked for:
-- "want to see if we can correlate activity to performance. or any outcomes." One row per
-- rep, activity (calls/emails/meetings/demos) and outcomes (pipeline created, closed-won
-- units) side by side, this month vs. last month, so a rep's activity drop and outcome drop
-- (or lack of one) are visible in the same row instead of two separate tables Sham has to
-- mentally cross-reference himself.
--
-- FAN-OUT AVOIDANCE -- same bug class already caught twice in this repo (insights_mix_shift.sql,
-- activity_cube.sql): five different source tables here (Task, Meeting, Opportunity-created,
-- Opportunity-closed), each aggregated to (period, rep) grain in its OWN CTE FIRST, then
-- joined together. Never join the raw fact tables to each other before aggregating -- that's
-- exactly what inflated activity_cube.sql's first draft 10-50x.
--
-- Same team_bucket exclusion as activity_cube.sql (DSMB/non-housing pods excluded, confirmed
-- live elsewhere in this repo that Karen Hsu/Alex Berg-style non-housing reps have
-- TEAM_NAME='none' and correctly drop out here too).
--
-- Deal-type scope on the outcome side (pipeline_created, closed_won_units) matches
-- performance_cube.sql: New Logo/Expansion/Move In only.
--
-- INACTIVE/CROSS-TEAM LEAKAGE FIX (2026-07-29) -- Kevin: "were showing a lot of inactive
-- users... and then non housing reps like saba obaid - shes on an entirely diff team - does
-- she not have some type of identifier that differentiates?" Root cause, confirmed live:
--   1. DIM_EMPLOYEE_HISTORY has NO active/inactive concept at all -- IS_CURRENT just means
--      "current SCD row," not "currently employed." This file never joined to
--      STG_SALESFORCE__USER (which has IS_ACTIVE/LAST_LOGIN_AT_UTC), so departed reps like
--      Zach Branson, Jacob Fidler, MJ Oommen, Jason Rosen never got filtered.
--   2. DIM_EMPLOYEE_HISTORY carries MULTIPLE IS_CURRENT=TRUE rows per person -- one per source
--      system (hubspot/jira/salesforce each write their own row). Confirmed live: 100% of
--      FCT_CRM_TASK/MEETING/OPPORTUNITY.EMPLOYEE_SK values resolve to SOURCE_SYSTEM='salesforce'
--      rows, so that's the only source system that matters for this join -- but even within
--      salesforce alone, some people (Zach Branson) have 2 rows (rehire/re-assignment), both
--      flagged current, which would otherwise double-count him across both SMB pods.
--   3. Saba Obaid -- the "entirely diff team" case -- IS active, and her TEAM_NAME genuinely
--      says 'Strategic Team'. The real tell is PARENT_TEAM: every actual Strategic AE has
--      PARENT_TEAM = 'Mid Market +'; hers is 'Revenue' -- she's tagged into the pod for
--      CRM/reporting convenience but isn't org-homed under sales management. Same guard also
--      drops a literal "- Duplicate" placeholder record and an unlogged-in placeholder that
--      both sit in Strategic Team with PARENT_TEAM = 'Strategic Team' (self-referencing, not
--      a real management parent).
-- FIX: team_map now dedupes DIM_EMPLOYEE_HISTORY down to one Salesforce-sourced row per
-- EMPLOYEE (by EMAIL, most-recently-updated), joins to a deduped STG_SALESFORCE__USER (same
-- QUALIFY pattern as rep_leaderboard.sql) for the real TEAM_NAME/PARENT_TEAM/IS_ACTIVE/
-- LAST_LOGIN_AT_UTC, requires PARENT_TEAM = 'Mid Market +' for the Strategic pod specifically,
-- and applies the same {{ GraceMonths.value }} (default 2) departure grace period as
-- rep_leaderboard.sql -- active OR logged in within the grace window, otherwise excluded.
-- THIS IS THE TEMPLATE PATTERN -- replicated identically in activity_cube.sql,
-- closed_won_by_rep.sql, full_funnel_by_segment.sql, insights_activity_to_outcome.sql,
-- opportunity_drilldown.sql, insights_stage_velocity.sql, and insights_activity_correlation.sql.

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
),
emp_dedup AS (
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
tasks AS (
    SELECT p.period, m.FULL_NAME AS rep,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_TASK t ON t.COMPLETED_AT_UTC BETWEEN p.start_date AND p.end_date AND t.TASK_STATUS = 'completed'
    JOIN team_map m ON t.EMPLOYEE_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    GROUP BY 1, 2
),
meets AS (
    SELECT p.period, m.FULL_NAME AS rep,
        COUNT(DISTINCT IFF(mt.MEETING_SUBTYPE = 'Sales | Demo', mt.MEETING_ID, NULL)) AS demos,
        COUNT(DISTINCT mt.MEETING_ID)                                                 AS meetings
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING mt ON mt.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date AND mt.MEETING_STATUS = 'completed'
    JOIN team_map m ON mt.EMPLOYEE_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    GROUP BY 1, 2
),
pipeline AS (
    SELECT p.period, m.FULL_NAME AS rep,
        COUNT(DISTINCT IFF(o.CREATED_AT_UTC BETWEEN p.start_date AND p.end_date, o.OPPORTUNITY_ID, NULL)) AS pipeline_created
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
    JOIN team_map m ON o.OWNER_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
    GROUP BY 1, 2
),
closed AS (
    SELECT p.period, m.FULL_NAME AS rep,
        SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date, o.FLEX_UNIT_COUNT, 0)) AS closed_won_units
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
    JOIN team_map m ON o.OWNER_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
    GROUP BY 1, 2
)
SELECT
    COALESCE(tk.period, mt.period, pl.period, cl.period)   AS period,
    COALESCE(tk.rep, mt.rep, pl.rep, cl.rep)                AS rep,
    COALESCE(tk.calls, 0)                                   AS calls,
    COALESCE(tk.emails, 0)                                  AS emails,
    COALESCE(mt.meetings, 0)                                AS meetings,
    COALESCE(mt.demos, 0)                                   AS demos,
    COALESCE(pl.pipeline_created, 0)                        AS pipeline_created,
    COALESCE(cl.closed_won_units, 0)                        AS closed_won_units
FROM tasks tk
FULL OUTER JOIN meets mt ON tk.period = mt.period AND tk.rep = mt.rep
FULL OUTER JOIN pipeline pl ON COALESCE(tk.period, mt.period) = pl.period AND COALESCE(tk.rep, mt.rep) = pl.rep
FULL OUTER JOIN closed cl ON COALESCE(tk.period, mt.period, pl.period) = cl.period AND COALESCE(tk.rep, mt.rep, pl.rep) = cl.rep
{{#Team.value}}
WHERE COALESCE(tk.rep, mt.rep, pl.rep, cl.rep) IN (
    SELECT FULL_NAME FROM team_map WHERE team_bucket = '{{Team.value}}'
)
{{/Team.value}}
ORDER BY period, closed_won_units DESC;
