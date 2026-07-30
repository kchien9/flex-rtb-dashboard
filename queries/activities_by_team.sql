-- Activities, by Team -- the middle drill level Kevin asked for: "start w all the activities
-- by segment then similarly to the rolled out units table, you can click into the segment
-- which reveals the team and then rep level." full_funnel_by_segment.sql is the top (segment)
-- level; activity_vs_outcome_by_rep.sql (filtered by Team) is the bottom (rep) level; this is
-- the middle. Same stages, same this-vs-last trending, grouped by team_bucket instead of
-- segment_bucket.
--
-- SDR CALLS DROPPED AT THIS LEVEL, ON PURPOSE -- checked live: SDR pods are segment-scoped,
-- not team-scoped (SMB SDRs/MM-Enterprise SDRs/Strategic SDRs -- no "Rory's SDRs" vs
-- "Sebastian's SDRs" split exists in Salesforce). Showing the same segment-level SDR number
-- twice under both Rory's Team and Sebastian's Team would look like a real team-level split
-- that doesn't exist -- dropped rather than faked. SDR Calls stays visible one level up, at
-- Segment, where it's real.
--
-- NO IMPLIED CAUSAL CHAIN -- same correction as full_funnel_by_segment.sql's header (updated
-- alongside this file): this shows AE Meetings/Pipeline Created/Closed Won/Rolled-Out Units
-- side by side with a trend, full stop. Don't read a drop in one column as caused by a drop in
-- an earlier one -- the lag/correlation between these stages was checked directly (see
-- project memory) and found too weak and inconsistent at monthly-aggregate grain to support
-- that story. Per Kevin: "i just want to show total activities and then the trends... the
-- causal table is creating a causal chain that may not exist."
--
-- Same fan-out avoidance (each stage aggregated to its own grain in its own CTE before
-- joining), same deal-type scope (New Logo/Expansion/Move In), same DSMB exclusion on
-- Rolled-Out Units, same dedup/grace-period rep-status handling as everywhere else in this
-- repo.

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
    SELECT EMAIL, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
team_map AS (
    SELECT ed.EMPLOYEE_SK,
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
ae_meetings AS (
    SELECT p.period, e.team_bucket AS team, COUNT(DISTINCT m.MEETING_ID) AS ae_meetings
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING m ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date
        AND m.MEETING_STATUS = 'completed'
    JOIN team_map e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.team_bucket IS NOT NULL
    GROUP BY 1, 2
),
pipeline_created AS (
    SELECT p.period, e.team_bucket AS team,
        COUNT(DISTINCT IFF(o.CREATED_AT_UTC BETWEEN p.start_date AND p.end_date, o.OPPORTUNITY_ID, NULL)) AS pipeline_created
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
    JOIN team_map e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.team_bucket IS NOT NULL
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
    GROUP BY 1, 2
),
closed_won AS (
    SELECT p.period, e.team_bucket AS team,
        SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date, o.FLEX_UNIT_COUNT, 0)) AS closed_won_units
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
    JOIN team_map e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.team_bucket IS NOT NULL
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
    GROUP BY 1, 2
),
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
rolled_out AS (
    SELECT
        IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), 'this_month', 'last_month_full') AS period,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS rolled_out_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
    GROUP BY 1, 2
    HAVING team IS NOT NULL
)
SELECT
    COALESCE(am.period, pc.period, cw.period, ro.period) AS period,
    COALESCE(am.team, pc.team, cw.team, ro.team) AS team,
    am.ae_meetings,
    pc.pipeline_created,
    cw.closed_won_units,
    ro.rolled_out_units
FROM ae_meetings am
FULL OUTER JOIN pipeline_created pc ON am.period = pc.period AND am.team = pc.team
FULL OUTER JOIN closed_won cw ON COALESCE(am.period, pc.period) = cw.period AND COALESCE(am.team, pc.team) = cw.team
FULL OUTER JOIN rolled_out ro ON COALESCE(am.period, pc.period, cw.period) = ro.period AND COALESCE(am.team, pc.team, cw.team) = ro.team
{{#Segment.value}}
WHERE COALESCE(am.team, pc.team, cw.team, ro.team) IN (
    SELECT team_bucket FROM (
        SELECT 'Brandon''s Team' AS team_bucket, 'MM/Ent' AS segment_bucket UNION ALL
        SELECT 'Sebastian''s Team', 'SMB' UNION ALL
        SELECT 'Rory''s Team', 'SMB' UNION ALL
        SELECT 'Dana''s Team', 'Strategic'
    ) WHERE segment_bucket = '{{Segment.value}}'
)
{{/Segment.value}}
ORDER BY team, period;
