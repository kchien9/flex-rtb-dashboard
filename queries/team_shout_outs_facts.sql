-- Team-Wide Shout Outs, Facts -- Kevin: "can we do team wide callouts too?... call out sdrs on
-- booked meetings too actually. so each ae team then sdrs on meetings! then team wide metrics
-- like the team hit a high on meetings bookings / calls. and the whole org - we rolled out 20%
-- more units this month over last." Same architecture as shout_outs_facts.sql (unchanged, stays
-- rep-grain) -- this is a sibling file at THREE grains: AE team, SDR pod, whole org. Same rule:
-- this query only gathers facts, a downstream LLM call narrates them -- never let the LLM
-- invent or compute a number.
--
-- SAME NON-NEGOTIABLE FRAMING RULE AS shout_outs_facts.sql, restated at this grain: every fact
-- compares an entity to ITS OWN prior period, or its own full history for the "hit a high"
-- facts -- never one team/pod ranked against another.
--
-- "HIT A HIGH" FACTS USE FULL AVAILABLE HISTORY, NOT A FIXED WINDOW -- deliberately learned
-- from the exact bug Kevin caught in shout_outs_facts.sql the same day ("cory's been at the
-- company longer than 6 months" -- a fixed 6-month lookback was silently understating what
-- "personal best" meant for a tenured rep). Applying that fix proactively here at team/pod
-- grain instead of waiting to get caught making the same mistake twice: `is_high` below
-- compares the current period against the max of EVERY prior period on record for that entity,
-- no month floor.
--
-- VALIDATED LIVE 2026-08-05 -- calibration, not hypothetical, check before writing example copy:
--   - Whole-org units (Part C): +20.8% MoM (337,707 vs 279,690) -- real, lines up with Kevin's
--     own "20% more units" example almost exactly.
--   - AE team units (Part A): all 4 teams up 15-31% MoM. AND a real is_high hit: Sebastian's
--     Team's current month (47,933 units) is genuinely its highest EVER on record (prior max
--     45,914) -- a legitimate "all-time high" story, not a fixed-window artifact, because this
--     check uses full history same as the fix just applied to shout_outs_facts.sql.
--   - SDR pod activity (Part B): genuinely DOWN, not up, this period. Calls flat-to-down (-4%
--     to +1%), meetings_booked down 50-80% across all 3 pods (comparing the last two FULLY
--     COMPLETE calendar months -- see Part B header for why the current partial month is
--     excluded entirely, not just flagged). No pod is currently "hitting a high" on calls or
--     meetings_booked against its own history either. This file surfaces that honestly -- it
--     must never force an SDR win that isn't real this period.
--
-- SELECTION GUIDANCE FOR THE LLM (not enforced in SQL -- "most compelling" is a narrative
-- judgment): prefer `is_high` over a plain MoM % for the same entity when both are true -- it's
-- the more specific, more celebratory framing ("highest month ever" beats "up 12%"). If an
-- entity's period-over-period change is flat or negative and it isn't hitting a high, don't
-- manufacture a positive spin -- either state the real number plainly or omit that entity from
-- this period's message, same rule as shout_outs_facts.sql's rep-level guidance.

-- Part A -- AE TEAM UNITS. Same BP-month anchor as shout_outs_facts.sql (MAX(BP_MONTH) = "this
-- month," always a settled, non-partial month). Same DSMB exclusion, same team_bucket mapping
-- via HUBSPOT_DEAL_OWNER -> STG_SALESFORCE__USER.TEAM_NAME used throughout this repo.
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
team_history AS (
    -- ALL BP months on record, no floor -- feeds both the MoM comparison and the is_high check.
    SELECT s.BP_MONTH, cr.team_bucket,
        SUM(IFF(s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN current_rep cr ON cr.FULL_NAME = s.HUBSPOT_DEAL_OWNER AND cr.team_bucket IS NOT NULL
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND (cr.IS_ACTIVE OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
    GROUP BY 1, 2
),
per_team AS (
    SELECT team_bucket,
        MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS this_period_value,
        MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)) AS last_period_value,
        MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS prior_max_value,
        COUNT(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), 1, NULL)) AS prior_period_count
    FROM team_history
    GROUP BY team_bucket
)
SELECT
    'team_units' AS fact_type,
    team_bucket AS entity,
    this_period_value,
    last_period_value,
    IFF(COALESCE(last_period_value, 0) > 0, this_period_value / last_period_value, NULL) AS mom_ratio,
    IFF(COALESCE(last_period_value, 0) > 0, (this_period_value - last_period_value) / last_period_value, NULL) AS mom_pct_change,
    IFF(COALESCE(this_period_value, 0) > 0 AND prior_period_count >= 2 AND this_period_value > COALESCE(prior_max_value, -1), TRUE, FALSE) AS is_high,
    prior_max_value
FROM per_team
WHERE team_bucket IS NOT NULL
  -- Materiality floor -- defensive backstop, not a live constraint today (every real AE team
  -- is 30K+ units/month) -- guards against a future thin/reorganized team's noise reading as a
  -- headline swing.
  AND COALESCE(last_period_value, 0) + COALESCE(this_period_value, 0) >= 2000
ORDER BY entity;

-- Part B -- SDR POD ACTIVITY (calls, meetings booked, meetings held). DELIBERATE DEPARTURE FROM
-- THE USUAL "FLAG, DON'T HIDE" PARTIAL-MONTH RULE. Every other file in this repo
-- (sdr_funnel_by_segment.sql, sdr_activity_by_rep.sql) flags the current in-progress calendar
-- month with `is_partial_month` and still shows it, because a dashboard viewer can read the
-- flag in context. A Slack shoutout has no such context -- it's a broadcast, read once, with no
-- filter UI. Comparing a few-days-old current month against a full prior month would silently
-- read as "activity collapsed," which is false (confirmed live: doing this naively showed calls
-- "down" 90%+ purely because the current month had 5 days of data). So this fact block SKIPS
-- the current partial calendar month entirely and compares the last TWO FULLY COMPLETE calendar
-- months instead, and uses FULL available history (every complete month on record) for the
-- is_high check, same full-history principle as Part A.
--
-- MEETINGS_BOOKED ADDED 2026-08-05, per Kevin: "call out sdrs on booked meetings too actually."
-- Booked = every meeting created in the period, any status (same definition
-- sdr_funnel_by_segment.sql already uses) -- distinct from meetings_held (completed only).
-- Validated live: booked is NOT simply a scaled-up version of held -- both dropped 50-80%
-- pod-over-pod the same period, a real, correlated decline, not independent noise.
--
-- CALLS/BOOKED/HELD ALL FLOORED SEPARATELY ON LAST-PERIOD VOLUME -- validated live: pod-month
-- meetings_booked and meetings_held are routinely single-to-low-double-digit (as low as 6-16 in
-- the months checked), too small a base to put a clean percent on, while calls is a much
-- steadier base (1,100-5,700/month). Floors: calls last-period >= 200, meetings_booked/held
-- last-period >= 10. Expect the meetings facts to be genuinely absent some periods when the
-- prior month itself was already thin -- that's the floor working as intended, not a bug.
--
-- Same sdr_segment pod mapping (SMB / MM/Ent / Strategic) as sdr_activity_by_rep.sql --
-- Strategic SDRs = 1 person (Louis Trujillo), carry that caveat into any Strategic-pod
-- narration same as every other SDR file in this repo.
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
-- Last two FULLY COMPLETE calendar months, for the MoM comparison.
target_months AS (
    SELECT DATEADD(month, -1, DATE_TRUNC('month', CURRENT_DATE())) AS this_period_mo,
           DATEADD(month, -2, DATE_TRUNC('month', CURRENT_DATE())) AS last_period_mo
),
activity_history AS (
    -- ALL complete calendar months on record (excludes the current in-progress month) --
    -- feeds both the MoM comparison and the is_high check.
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo, e.sdr_segment,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL)) AS calls
    FROM FLEX.SALES.FCT_CRM_TASK t
    JOIN emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    WHERE t.TASK_STATUS = 'completed'
      AND t.COMPLETED_AT_UTC < DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY 1, 2
),
meetings_history AS (
    SELECT DATE_TRUNC('month', m.CREATED_AT_UTC) AS mo, e.sdr_segment,
        COUNT(*) AS meetings_booked,
        SUM(IFF(m.MEETING_STATUS = 'completed', 1, 0)) AS meetings_held
    FROM FLEX.SALES.FCT_CRM_MEETING m
    JOIN emp e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    WHERE m.CREATED_AT_UTC < DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY 1, 2
),
combined AS (
    SELECT COALESCE(a.sdr_segment, mt.sdr_segment) AS sdr_segment, COALESCE(a.mo, mt.mo) AS mo,
        COALESCE(a.calls, 0) AS calls,
        COALESCE(mt.meetings_booked, 0) AS meetings_booked,
        COALESCE(mt.meetings_held, 0) AS meetings_held
    FROM activity_history a
    FULL OUTER JOIN meetings_history mt ON a.mo = mt.mo AND a.sdr_segment = mt.sdr_segment
    WHERE COALESCE(a.sdr_segment, mt.sdr_segment) IS NOT NULL
),
per_pod AS (
    SELECT c.sdr_segment,
        MAX(IFF(c.mo = tm.this_period_mo, c.calls, NULL))            AS calls_this,
        MAX(IFF(c.mo = tm.last_period_mo, c.calls, NULL))            AS calls_last,
        MAX(IFF(c.mo < tm.this_period_mo, c.calls, NULL))            AS calls_prior_max,
        MAX(IFF(c.mo = tm.this_period_mo, c.meetings_booked, NULL))  AS booked_this,
        MAX(IFF(c.mo = tm.last_period_mo, c.meetings_booked, NULL))  AS booked_last,
        MAX(IFF(c.mo < tm.this_period_mo, c.meetings_booked, NULL))  AS booked_prior_max,
        MAX(IFF(c.mo = tm.this_period_mo, c.meetings_held, NULL))    AS held_this,
        MAX(IFF(c.mo = tm.last_period_mo, c.meetings_held, NULL))    AS held_last,
        MAX(IFF(c.mo < tm.this_period_mo, c.meetings_held, NULL))    AS held_prior_max,
        COUNT(IFF(c.mo < tm.this_period_mo, 1, NULL))                AS prior_period_count
    FROM combined c
    CROSS JOIN target_months tm
    GROUP BY c.sdr_segment
)
SELECT 'sdr_calls' AS fact_type, sdr_segment AS entity,
    COALESCE(calls_this, 0) AS this_period_value, COALESCE(calls_last, 0) AS last_period_value,
    IFF(calls_last > 0, calls_this / calls_last, NULL) AS mom_ratio,
    IFF(calls_last > 0, (calls_this - calls_last) / calls_last, NULL) AS mom_pct_change,
    IFF(COALESCE(calls_this, 0) > 0 AND prior_period_count >= 2 AND calls_this > COALESCE(calls_prior_max, -1), TRUE, FALSE) AS is_high,
    calls_prior_max AS prior_max_value
FROM per_pod WHERE COALESCE(calls_last, 0) >= 200
UNION ALL
-- Column NAMES below come from the branch above (positional UNION ALL) -- values are correct
-- per-metric (validated live: booked_prior_max/held_prior_max are real, distinct numbers from
-- calls_prior_max, not an accidental copy), only the alias `prior_max_value` is shared on
-- purpose so every fact_type exposes the same column name for "this metric's best-ever period."
SELECT 'sdr_meetings_booked' AS fact_type, sdr_segment AS entity,
    COALESCE(booked_this, 0), COALESCE(booked_last, 0),
    IFF(booked_last > 0, booked_this / booked_last, NULL),
    IFF(booked_last > 0, (booked_this - booked_last) / booked_last, NULL),
    IFF(COALESCE(booked_this, 0) > 0 AND prior_period_count >= 2 AND booked_this > COALESCE(booked_prior_max, -1), TRUE, FALSE),
    booked_prior_max
FROM per_pod WHERE COALESCE(booked_last, 0) >= 10
UNION ALL
SELECT 'sdr_meetings_held' AS fact_type, sdr_segment AS entity,
    COALESCE(held_this, 0), COALESCE(held_last, 0),
    IFF(held_last > 0, held_this / held_last, NULL),
    IFF(held_last > 0, (held_this - held_last) / held_last, NULL),
    IFF(COALESCE(held_this, 0) > 0 AND prior_period_count >= 2 AND held_this > COALESCE(held_prior_max, -1), TRUE, FALSE),
    held_prior_max
FROM per_pod WHERE COALESCE(held_last, 0) >= 10
ORDER BY entity, fact_type;

-- Part C -- WHOLE ORG UNITS, MoM. Same anchor/exclusion pattern as Part A, just without the
-- team join -- every DSMB-excluded rolled-out unit company-wide, not restricted to reps
-- currently matched to one of the 4 named AE teams (a team-restricted sum would silently
-- understate the real company total by however many units belong to unmatched/departed reps).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
org_history AS (
    SELECT s.BP_MONTH,
        SUM(IFF(s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
    GROUP BY 1
)
SELECT
    'org_units' AS fact_type,
    'Whole Org' AS entity,
    MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS this_period_value,
    MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)) AS last_period_value,
    IFF(MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)) > 0,
        MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL))
            / MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)),
        NULL) AS mom_ratio,
    IFF(MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)) > 0,
        (MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL))
            - MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)))
            / MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)),
        NULL) AS mom_pct_change,
    IFF(MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) > 0
            AND COUNT(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), 1, NULL)) >= 2
            AND MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL))
                > COALESCE(MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)), -1),
        TRUE, FALSE) AS is_high,
    MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS prior_max_value
FROM org_history;
