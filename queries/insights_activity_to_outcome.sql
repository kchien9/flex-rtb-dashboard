-- DEPRECATED 2026-07-30 -- Kevin: "i think this activity to outcome table can be deprecated
-- bc we cant really create a causal chain... the causal table is creating a causal chain that
-- may not exist." Both parts below frame activity as explaining/predicting outcomes, which the
-- direct correlation check (see project memory) found too weak and inconsistent to support at
-- monthly-aggregate grain. Replaced by full_funnel_by_segment.sql (segment) /
-- activities_by_team.sql (team) / activity_vs_outcome_by_rep.sql (rep) -- same numbers, side by
-- side, no causal narrative. Leave this file in place until Superblocks unwires whatever still
-- points to it, then delete -- don't rebuild anything on top of it in the meantime.
--
-- Activity -> Outcome diagnostics -- two real questions Kevin wants answerable without
-- digging: "why are we having a slow week -- should be bc lack of meetings, so less
-- pipeline" (which reps specifically dropped meetings, pacing-matched) and "we saw an uptick
-- in new logo meetings, did this lead to new logo units" (does activity actually show up in
-- outcomes, by deal type, not just in aggregate).
--
-- Part A: rep-level meeting pacing, this_month vs last_month_mtd -- who specifically dropped
-- off, not just "the team is down." This is the rep-level complement to
-- insights_activity_correlation.sql's team-level version -- same underlying idea
-- (Meetings->Units causal chain), narrower grain. Real validated example: Umar Khan
-- (Brandon's Team) down from 28 to 3 meetings, Ruby Baer down from 34 to 13 -- exactly the
-- "2 reps dropped the ball" pattern Kevin described, not hypothetical.
--
-- INACTIVE/CROSS-TEAM LEAKAGE FIX (2026-07-29) -- same root cause and fix as
-- activity_vs_outcome_by_rep.sql's header -- meets now dedupes DIM_EMPLOYEE_HISTORY to the
-- Salesforce-sourced row and joins deduped STG_SALESFORCE__USER (PARENT_TEAM='Mid Market +'
-- required for the Strategic pod, standard {{ GraceMonths.value }} grace period).
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
    SELECT 'last_month_mtd',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,bp_month_label)), LEAST(DATEADD(day,3,bp_month_label), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -2, bp_month_label)))
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
meets AS (
    SELECT p.period, m.FULL_NAME AS rep, m.team_bucket,
        COUNT(*) AS meetings
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING mt ON mt.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date AND mt.MEETING_STATUS = 'completed'
    JOIN team_map m ON mt.EMPLOYEE_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    GROUP BY 1, 2, 3
)
SELECT
    rep, team_bucket,
    MAX(IFF(period = 'this_month', meetings, 0))       AS meetings_this_month,
    MAX(IFF(period = 'last_month_mtd', meetings, 0))   AS meetings_last_month_mtd,
    MAX(IFF(period = 'this_month', meetings, 0)) - MAX(IFF(period = 'last_month_mtd', meetings, 0)) AS change
FROM meets
WHERE team_bucket IS NOT NULL
  {{#Team.value}} AND team_bucket = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2
HAVING meetings_this_month > 0 OR meetings_last_month_mtd > 0
ORDER BY change ASC;

-- Part B: New Logo meetings vs. New Logo closed-won units, trailing 6 months. Answers "did
-- an uptick in New Logo meetings actually lead to New Logo units" by just putting both series
-- next to each other -- deliberately NOT a fitted lag-correlation model (matches the
-- "interpretability over accuracy" standard -- a sales leader can eyeball two adjacent
-- columns, a regression coefficient he'd have to trust blindly).
--
-- APPROXIMATION, stated plainly: there's no direct meeting -> opportunity link in the schema
-- (FCT_CRM_MEETING only carries CRM_ACCOUNT_SK, not an OPPORTUNITY_ID). A meeting counts as
-- "New Logo" here if the SAME ACCOUNT has a New Logo opportunity created within 45 days of
-- that meeting -- a real but approximate attribution, not a guaranteed 1:1 link. Validated
-- live: meetings and units both show a real rising trend over the last 6 months (7->585
-- meetings, ~$8K->~150K units), though not perfectly monotonic month to month (June had more
-- meetings than July but fewer units) -- show the real noise, don't smooth it into a cleaner
-- story than the data supports.
WITH new_logo_meetings AS (
    SELECT DISTINCT DATE_TRUNC('month', m.STARTED_AT_UTC) AS month, m.MEETING_ID
    FROM FLEX.SALES.FCT_CRM_MEETING m
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o
        ON m.CRM_ACCOUNT_SK = o.CRM_ACCOUNT_SK AND o.OPPORTUNITY_TYPE = 'New Logo'
    WHERE m.MEETING_STATUS = 'completed'
      AND o.CREATED_AT_UTC BETWEEN DATEADD(day, -45, m.STARTED_AT_UTC) AND DATEADD(day, 45, m.STARTED_AT_UTC)
      AND m.STARTED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
),
meetings_by_month AS (
    SELECT month, COUNT(*) AS new_logo_meetings FROM new_logo_meetings GROUP BY 1
),
units_by_month AS (
    SELECT DATE_TRUNC('month', CLOSED_AT_UTC) AS month, SUM(FLEX_UNIT_COUNT) AS new_logo_units
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY
    WHERE IS_CLOSED_WON AND OPPORTUNITY_TYPE = 'New Logo'
      AND CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
    GROUP BY 1
)
SELECT m.month, m.new_logo_meetings, u.new_logo_units
FROM meetings_by_month m
LEFT JOIN units_by_month u ON m.month = u.month
ORDER BY 1;
