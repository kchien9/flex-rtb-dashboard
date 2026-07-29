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
team_map AS (
    SELECT EMPLOYEE_SK, FULL_NAME,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE IS_CURRENT = TRUE
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
