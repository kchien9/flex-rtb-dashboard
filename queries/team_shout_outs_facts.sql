-- Team-Wide Shout Outs, Facts -- Kevin: "can we do team wide callouts too? like 'the team
-- rolled out 3x more units this month than last!', the 'sdrs crushed the phones, booking 2x
-- more meetings/making 200% more calls this month.'" Same architecture as shout_outs_facts.sql
-- (which stays rep-grain, unchanged) -- this is a sibling file at TEAM/POD grain. Same rule:
-- this query only gathers facts, a downstream LLM call narrates them -- never let the LLM
-- invent or compute a number.
--
-- SAME NON-NEGOTIABLE FRAMING RULE AS shout_outs_facts.sql, restated at this grain: every fact
-- here compares a team/pod to ITS OWN prior month, never to another team/pod. "AE Team A grew
-- units 30% while Team B only grew 15%" is exactly the kind of comparison the framing rule
-- forbids -- this file never joins one team's numbers against another's for narration purposes.
--
-- VALIDATED LIVE 2026-08-05 -- CHECK THIS BEFORE WRITING ANY EXAMPLE COPY: real current
-- multiples are nowhere near Kevin's own "3x"/"2x"/"200%" illustrative examples. Real trailing
-- BP-month unit growth by AE team: Dana's +30%, Brandon's +31%, Sebastian's +17%, Rory's +15%.
-- Real SDR pod activity (see Part B) is FLAT TO DOWN month-over-month right now, not up at all.
-- This file must never force a celebratory number that isn't real -- if the current period's
-- honest number is flat or negative, the downstream narration should either skip that pod/team
-- for this message or state the real number plainly -- it must not manufacture a growth framing
-- to match the tone Kevin was illustrating.
--
-- PART A -- AE TEAM UNITS, MoM. Same BP-month anchor as shout_outs_facts.sql
-- (MAX(BP_MONTH) = "this month," the prior BP_MONTH = "last month" -- BP months close a few
-- days into the next calendar month, so MAX(BP_MONTH) is always a settled, non-partial month,
-- never the still-forming current one). Same DSMB exclusion, same team_bucket mapping via
-- HUBSPOT_DEAL_OWNER -> STG_SALESFORCE__USER.TEAM_NAME used throughout this repo.
--
-- PART B -- SDR POD ACTIVITY, MoM -- DELIBERATE DEPARTURE FROM THE USUAL "FLAG, DON'T HIDE"
-- PARTIAL-MONTH RULE. Every other file in this repo (sdr_funnel_by_segment.sql,
-- sdr_activity_by_rep.sql) flags the current in-progress calendar month with
-- `is_partial_month` and still SHOWS it, because a dashboard viewer can see the flag and read
-- it in context. A Slack shoutout message has no such context -- it's a broadcast, read once,
-- with no filter UI. Comparing a 5-days-old August against a full June would silently read as
-- "calls collapsed 90%," which is false. So this fact block SKIPS the current partial calendar
-- month entirely and compares the last TWO FULLY COMPLETE calendar months instead (confirmed
-- live: comparing Aug-so-far vs. Jul this way showed calls "down" 90%+ across every pod purely
-- because Aug had 5 days of data -- a real near-miss, not a hypothetical concern).
--
-- MEETINGS_HELD FLOORED SEPARATELY FROM CALLS -- validated live: pod-month meetings_held is
-- routinely single-digit (3-31 across 3 pods x 3 months checked), too small a base to put a
-- clean percent on, while calls is a much steadier base (1,100-5,700/month). Requiring
-- `last_month_meetings_held >= 10` before exposing a meetings ratio is NOT currently a
-- rare edge case -- real recent data trips this floor for multiple pod-months (e.g. Jul 2026:
-- MM/Ent=5, SMB=3, Strategic=5, all below the floor) -- expect the meetings fact to be
-- genuinely absent most periods, not a hypothetical safeguard that never fires.
--
-- Same sdr_segment pod mapping (SMB / MM/Ent / Strategic) as sdr_activity_by_rep.sql --
-- Strategic SDRs = 1 person (Louis Trujillo), carry that caveat into any Strategic-pod
-- narration same as every other SDR file in this repo.

-- Part A
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
user_dedup AS (
    SELECT FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
current_rep AS (
    SELECT FULL_NAME,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM user_dedup
),
team_monthly AS (
    SELECT s.BP_MONTH, cr.team_bucket,
        SUM(IFF(s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN current_rep cr ON cr.FULL_NAME = s.HUBSPOT_DEAL_OWNER AND cr.team_bucket IS NOT NULL
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND (cr.IS_ACTIVE OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
      AND s.BP_MONTH IN (
            (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS),
            DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
          )
    GROUP BY 1, 2
)
SELECT
    'team_units' AS fact_type,
    team_bucket AS entity,
    MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS this_period_value,
    MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS last_period_value,
    -- Ratio and pct_change both exposed -- narration picks "3x" framing vs. "40% more" framing
    -- by magnitude, but never computes the division itself. NULL (not 0) when last_period_value
    -- is 0 or missing, so a real "New" case doesn't silently read as 0% -- same blank-handling
    -- convention as sdr_activity_by_rep.sql / the locked §4.14 MoM badge rule.
    IFF(MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) > 0,
        MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL))
            / MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)),
        NULL) AS ratio,
    IFF(MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) > 0,
        (MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL))
            - MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)))
            / MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)),
        NULL) AS pct_change
FROM team_monthly
WHERE team_bucket IS NOT NULL
GROUP BY team_bucket
-- Materiality floor -- defensive backstop, not a live constraint today (every real AE team is
-- 30K+ units/month) -- guards against a future thin/reorganized team's noise reading as a
-- headline swing.
HAVING COALESCE(MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)), 0)
     + COALESCE(MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)), 0) >= 2000
ORDER BY entity;

-- Part B
WITH emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, TEAM_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
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
        END AS sdr_segment
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
-- Last two FULLY COMPLETE calendar months -- deliberately excludes the current in-progress
-- month entirely (see header). "This period" = the most recent complete month -- "last period"
-- = the one before it.
target_months AS (
    SELECT DATEADD(month, -1, DATE_TRUNC('month', CURRENT_DATE())) AS this_period_mo,
           DATEADD(month, -2, DATE_TRUNC('month', CURRENT_DATE())) AS last_period_mo
),
activity AS (
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo, e.sdr_segment,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL)) AS calls
    FROM FLEX.SALES.FCT_CRM_TASK t
    JOIN emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    CROSS JOIN target_months tm
    WHERE t.TASK_STATUS = 'completed'
      AND DATE_TRUNC('month', t.COMPLETED_AT_UTC) IN (tm.this_period_mo, tm.last_period_mo)
    GROUP BY 1, 2
),
meetings AS (
    SELECT DATE_TRUNC('month', m.CREATED_AT_UTC) AS mo, e.sdr_segment,
        SUM(IFF(m.MEETING_STATUS = 'completed', 1, 0)) AS meetings_held
    FROM FLEX.SALES.FCT_CRM_MEETING m
    JOIN emp e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    CROSS JOIN target_months tm
    WHERE DATE_TRUNC('month', m.CREATED_AT_UTC) IN (tm.this_period_mo, tm.last_period_mo)
    GROUP BY 1, 2
),
combined AS (
    SELECT COALESCE(a.sdr_segment, mt.sdr_segment) AS sdr_segment,
        MAX(IFF(a.mo = tm.this_period_mo, a.calls, NULL))            AS calls_this,
        MAX(IFF(a.mo = tm.last_period_mo, a.calls, NULL))            AS calls_last,
        MAX(IFF(mt.mo = tm.this_period_mo, mt.meetings_held, NULL))  AS meetings_this,
        MAX(IFF(mt.mo = tm.last_period_mo, mt.meetings_held, NULL))  AS meetings_last
    FROM activity a
    FULL OUTER JOIN meetings mt ON a.mo = mt.mo AND a.sdr_segment = mt.sdr_segment
    CROSS JOIN target_months tm
    WHERE COALESCE(a.sdr_segment, mt.sdr_segment) IS NOT NULL
    GROUP BY 1
)
SELECT
    'sdr_calls' AS fact_type,
    sdr_segment AS entity,
    COALESCE(calls_this, 0) AS this_period_value,
    COALESCE(calls_last, 0) AS last_period_value,
    IFF(COALESCE(calls_last, 0) > 0, COALESCE(calls_this, 0) / calls_last, NULL) AS ratio,
    IFF(COALESCE(calls_last, 0) > 0, (COALESCE(calls_this, 0) - calls_last) / calls_last, NULL) AS pct_change
FROM combined
WHERE COALESCE(calls_last, 0) >= 200  -- materiality floor, calls -- real pods run 1,100-5,700/mo
UNION ALL
SELECT
    'sdr_meetings_held' AS fact_type,
    sdr_segment AS entity,
    COALESCE(meetings_this, 0) AS this_period_value,
    COALESCE(meetings_last, 0) AS last_period_value,
    IFF(COALESCE(meetings_last, 0) > 0, COALESCE(meetings_this, 0) / meetings_last, NULL) AS ratio,
    IFF(COALESCE(meetings_last, 0) > 0, (COALESCE(meetings_this, 0) - meetings_last) / meetings_last, NULL) AS pct_change
FROM combined
WHERE COALESCE(meetings_last, 0) >= 10  -- materiality floor, meetings -- routinely single-digit, see header
ORDER BY entity, fact_type;
