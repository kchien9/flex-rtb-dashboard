-- DEPRECATED 2026-07-30, SUPERSEDED ENTIRELY (not just reframed) -- Kevin, after an initial
-- attempt to just remove the causal narrative text from this table: "remove the whole table bc
-- we cannot show this causal chain at all. I just want segment then calls emails meetings
-- demos." Even without narrative text, arranging SDR Calls/AE Meetings next to Pipeline
-- Created/Closed Won/Rolled-Out Units in one row still visually implies a chain. Replaced by
-- activities_by_segment.sql (pure Calls/Emails/Meetings/Demos, no outcome columns at all) for
-- the Activities tab -- outcomes already have their own home on Deals & Units
-- (performance_cube.sql) and Pipeline (rolled_out_units_cube.sql), no second appearance needed
-- here. Leave this file in place until Superblocks unwires it, then delete.

-- Full Funnel, by Segment -- the end-to-end chain Kevin originally described: "it starts w
-- sdrs activity and that leads to meetings which create pipeline which lead to closed units
-- which lead to rolled out units." Five stages, side by side, by segment, this month vs last
-- month. Superseded per the note above -- kept only for reference.
--
-- SDR pods map cleanly onto the same 3 segments that have dedicated SDR support -- confirmed
-- live: SMB SDRs, MM/Enterprise SDRs, Strategic SDRs (Deep SMB SDRs excluded, same DSMB
-- exclusion as everywhere else; House Accounts and Not Set have no dedicated SDR pod, those
-- two segments show NULL for the SDR/meetings stages, not zero -- don't conflate "no SDR
-- pod exists" with "SDR activity was zero," they're different facts).
--
-- SDR_SK ON FCT_CRM_OPPORTUNITY IS NOT RELIABLE ENOUGH FOR THIS -- checked live 2026-07-28:
-- 87.5% of opportunities (5,271 of 6,026 in a 3-month window) resolve to a placeholder
-- "none" user via SDR_SK, only 12.5% have a real named SDR attached. Rather than build an
-- individual-rep SDR-to-AE pairing on a field that's mostly unpopulated, this uses the
-- SDR-pod-to-AE-segment mapping instead (e.g. all of Strategic SDRs' calls vs. all of Dana's
-- Team's meetings) -- a segment-level correlation, not a claim that any specific SDR sourced
-- any specific AE's specific meeting.
--
-- FAN-OUT AVOIDANCE -- five source tables (Task, Meeting, Opportunity-created,
-- Opportunity-closed, PROPERTY_BP_MONTH_STATS), each aggregated to (period, segment) grain
-- in its own CTE before joining -- same discipline as activity_vs_outcome_by_rep.sql.
--
-- Deal-type scope on the deal-grain stages (pipeline created, closed won) matches
-- performance_cube.sql: New Logo/Expansion/Move In only. Rolled-Out Units stays DSMB-excluded
-- via the standard pmc_size CTE, same as rolled_out_units_cube.sql.
--
-- Validated live 2026-07-28: MM/Ent SDR calls down 11% (2,238 -> 1,981) and AE meetings down
-- 61% (109 -> 42) in the same window -- both real numbers, shown side by side. NOT claiming
-- one caused the other (see the "NO IMPLIED CAUSAL CHAIN" note above, added 2026-07-30) --
-- this specific pair moving together in one window isn't the same as a proven lag relationship
-- across time; the direct correlation check found the broader pattern too weak to trust.
--
-- INACTIVE/CROSS-TEAM LEAKAGE FIX (2026-07-29) -- same root cause and fix as
-- activity_vs_outcome_by_rep.sql's header. emp now dedupes DIM_EMPLOYEE_HISTORY to the
-- Salesforce-sourced row and joins deduped STG_SALESFORCE__USER for real TEAM_NAME/
-- PARENT_TEAM/IS_ACTIVE/LAST_LOGIN_AT_UTC (PARENT_TEAM='Mid Market +' required for the
-- Strategic ae_segment), applying the standard {{ GraceMonths.value }} grace period -- this
-- matters here even though the output is segment-level, not rep-level, because a departed or
-- mis-tagged rep's activity/units would otherwise silently inflate a segment total.
--
-- SDR HEADCOUNT TRANSPARENCY (2026-07-29) -- Kevin: "how are you segmenting sdr calls? are
-- you looking at the sdr segment? louis trujillo is the only strategic sdr." Confirmed live --
-- he's exactly right, and it's worse than "mostly one person": Strategic SDRs has ONE person
-- total, period (MM/Enterprise SDRs has 3 active, SMB SDRs has 7). So the Strategic column in
-- sdr_calls is literally Louis Trujillo's individual activity, not a team signal -- his PTO or
-- a bad day reads as "Strategic SDR activity collapsed," which is misleading without context.
-- Added `sdr_headcount` (COUNT DISTINCT active SDRs who logged at least one call that period,
-- not the pod's static roster size) so a 1-person column is visibly different from a 7-person
-- one wherever this is displayed -- same "don't hide small sample size" principle as
-- sales_cycle_time_by_segment.sql's `deals`/`deals_with_touch` columns.

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
emp AS (
    SELECT ed.EMPLOYEE_SK,
        CASE
            WHEN u.TEAM_NAME = 'SMB SDRs' THEN 'SMB'
            WHEN u.TEAM_NAME = 'MM/Enterprise SDRs' THEN 'MM/Ent'
            WHEN u.TEAM_NAME = 'Strategic SDRs' THEN 'Strategic'
            ELSE NULL
        END AS sdr_segment,
        CASE
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
            WHEN u.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN u.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS ae_segment
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
sdr_calls AS (
    SELECT p.period, e.sdr_segment AS segment,
        COUNT(DISTINCT t.TASK_ID) AS sdr_calls,
        COUNT(DISTINCT t.EMPLOYEE_SK) AS sdr_headcount
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_TASK t ON t.COMPLETED_AT_UTC BETWEEN p.start_date AND p.end_date
        AND t.TASK_STATUS = 'completed' AND t.TASK_TYPE = 'call'
    JOIN emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    GROUP BY 1, 2
),
ae_meetings AS (
    SELECT p.period, e.ae_segment AS segment, COUNT(DISTINCT m.MEETING_ID) AS ae_meetings
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING m ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date
        AND m.MEETING_STATUS = 'completed'
    JOIN emp e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.ae_segment IS NOT NULL
    GROUP BY 1, 2
),
pipeline_created AS (
    SELECT p.period, e.ae_segment AS segment,
        COUNT(DISTINCT IFF(o.CREATED_AT_UTC BETWEEN p.start_date AND p.end_date, o.OPPORTUNITY_ID, NULL)) AS pipeline_created
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
    JOIN emp e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.ae_segment IS NOT NULL
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
    GROUP BY 1, 2
),
closed_won AS (
    SELECT p.period, e.ae_segment AS segment,
        SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date, o.FLEX_UNIT_COUNT, 0)) AS closed_won_units
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
    JOIN emp e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.ae_segment IS NOT NULL
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
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS rolled_out_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
    GROUP BY 1, 2
    HAVING segment IS NOT NULL
)
SELECT
    COALESCE(sc.period, am.period, pc.period, cw.period, ro.period) AS period,
    COALESCE(sc.segment, am.segment, pc.segment, cw.segment, ro.segment) AS segment,
    sc.sdr_calls,
    sc.sdr_headcount,
    am.ae_meetings,
    pc.pipeline_created,
    cw.closed_won_units,
    ro.rolled_out_units
FROM sdr_calls sc
FULL OUTER JOIN ae_meetings am ON sc.period = am.period AND sc.segment = am.segment
FULL OUTER JOIN pipeline_created pc ON COALESCE(sc.period, am.period) = pc.period AND COALESCE(sc.segment, am.segment) = pc.segment
FULL OUTER JOIN closed_won cw ON COALESCE(sc.period, am.period, pc.period) = cw.period AND COALESCE(sc.segment, am.segment, pc.segment) = cw.segment
FULL OUTER JOIN rolled_out ro ON COALESCE(sc.period, am.period, pc.period, cw.period) = ro.period AND COALESCE(sc.segment, am.segment, pc.segment, cw.segment) = ro.segment
ORDER BY segment, period;
