-- Forward Pipeline Trend -- Kevin: "i want forward pipeline to be part of our ai callout
-- debrief. if units are forecasting lower next month we need to call it out. and then if we
-- can identify reasons why, like strategic segment was driver w 50% less units MoM."
--
-- WHY THIS ISN'T "NEXT MONTH'S FORECAST VS. THIS MONTH'S ACTUAL" -- checked and rejected before
-- building: a forecast for a future month mechanically GROWS every day as more deals close
-- into it (pipeline_forecast.sql's own validated finding -- closed-awaiting-rollout units
-- concentrate in the very next month and keep accumulating as it approaches). Comparing that
-- still-forming number against a fully-settled past actual would read as "lower" almost every
-- single month by construction, not because pipeline is really shrinking. Confirmed this
-- reframing with Kevin directly before building: instead, track the SAME target month's OWN
-- forecast over time -- what did we expect for month X a month ago vs. what do we expect for
-- month X today. A real decline in the same month's own number, watched over time, is the
-- honest signal.
--
-- "AS OF N DAYS AGO" IS A COHORT RECONSTRUCTION, NOT A STORED SNAPSHOT -- pipeline_forecast.sql
-- never snapshotted its own output historically, so this can't be a literal replay. Rebuilt
-- using real timestamps that ARE stamped historically (CREATED_AT_UTC, CLOSED_AT_UTC):
--   - closed_awaiting_rollout leg: only counts deals that had ALREADY closed by
--     (today - {{ AsOfDaysAgo.value }} days) -- a deal that closed AFTER that point wasn't
--     part of the forecast yet back then, by definition.
--   - open_pipeline leg: only counts deals that EXISTED AND WERE STILL OPEN as of that same
--     past point (CREATED_AT_UTC <= as-of-date AND (not yet closed, OR closed after
--     as-of-date)).
-- HONEST LIMITATION, stated plainly -- this uses each opportunity's CURRENT
-- ANTICIPATED_GO_LIVE_AT_UTC/ROLLOUT_MONTH value, not a true historical snapshot of what that
-- field said N days ago (no field-history table exists for it). If a deal's anticipated month
-- got pushed back since then, this won't catch that specific drift -- it answers "of the deals
-- that existed as of N days ago, what does their CURRENT anticipated month say," a real,
-- useful approximation, not a perfect point-in-time replay. A large gap between the as-of-
-- today and as-of-N-days-ago DEAL COUNT (not just units) for the same cohort is itself worth
-- surfacing -- deals vanishing from a cohort between the two as-of dates means they either got
-- pushed to a different month or closed lost, either of which Sham would want named, not just
-- implied by a units delta.
--
-- SEGMENT BREAKDOWN IS NEW -- neither part of pipeline_forecast.sql cuts by segment_bucket
-- (Part A there only has team_bucket, Part B has no breakdown at all). Added here specifically
-- so a company-wide decline can be attributed to a driver, per Kevin's own example ("strategic
-- segment was driver w 50% less units"). Same OWNER_SK -> DIM_EMPLOYEE_HISTORY.TEAM_NAME
-- attribution as pipeline_forecast.sql (STATIC_TEAM_NAME is almost entirely NULL on open
-- opportunities, already validated there).
--
-- TWO LEGS, NOT BLENDED -- same non-negotiable rule pipeline_forecast.sql's header already
-- established: closed-awaiting-rollout carries real 88% historical accuracy, open pipeline is
-- unweighted face value with no accuracy backing. Part A is the high-confidence leg (the one
-- that should actually drive a callout); Part B is the low-confidence leg (context only, never
-- the headline). Same DSMB exclusion, New Vertical exclusion (2026-08-05 fix), and 5-year
-- sanity ceiling as pipeline_forecast.sql.

-- Part A: closed-awaiting-rollout leg, as-of-today vs. as-of-N-days-ago, by segment, for each
-- of the next {{ TargetMonthsAhead.value }} months.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
target_months AS (
    SELECT DATEADD(month, SEQ4() + 1, DATE_TRUNC('month', CURRENT_DATE())) AS target_month
    FROM TABLE(GENERATOR(ROWCOUNT => {{ TargetMonthsAhead.value }}))
),
scoped AS (
    SELECT li.OPPORTUNITY_ID, li.UNIT_COUNT, li.ROLLOUT_MONTH, o.CLOSED_AT_UTC,
        COALESCE(
            CASE
                WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
                WHEN e.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                ELSE NULL
            END, 'Not Set') AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED_WON
      AND o.OPPORTUNITY_TYPE != 'New Vertical'
      AND li.ROLLOUT_MONTH <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
)
SELECT
    tm.target_month,
    s.segment_bucket,
    SUM(s.UNIT_COUNT)                                                              AS units_as_of_today,
    COUNT(DISTINCT s.OPPORTUNITY_ID)                                               AS deals_as_of_today,
    SUM(IFF(s.CLOSED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE()), s.UNIT_COUNT, 0)) AS units_as_of_n_days_ago,
    COUNT(DISTINCT IFF(s.CLOSED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE()), s.OPPORTUNITY_ID, NULL)) AS deals_as_of_n_days_ago
FROM target_months tm
JOIN scoped s ON DATE_TRUNC('month', s.ROLLOUT_MONTH) = tm.target_month
GROUP BY 1, 2
ORDER BY 1, 2;

-- Part B: open-pipeline leg, as-of-today vs. as-of-N-days-ago, by segment. Low confidence --
-- context only, never the headline callout number.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
target_months AS (
    SELECT DATEADD(month, SEQ4() + 1, DATE_TRUNC('month', CURRENT_DATE())) AS target_month
    FROM TABLE(GENERATOR(ROWCOUNT => {{ TargetMonthsAhead.value }}))
),
scoped AS (
    SELECT o.OPPORTUNITY_ID, o.FLEX_UNIT_COUNT, o.ANTICIPATED_GO_LIVE_AT_UTC,
        o.CREATED_AT_UTC, o.CLOSED_AT_UTC,
        COALESCE(
            CASE
                WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
                WHEN e.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                ELSE NULL
            END, 'Not Set') AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE NOT o.IS_CLOSED
      AND o.OPPORTUNITY_TYPE != 'New Vertical'
      AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
)
SELECT
    tm.target_month,
    s.segment_bucket,
    SUM(s.FLEX_UNIT_COUNT)                                                          AS units_as_of_today,
    COUNT(DISTINCT s.OPPORTUNITY_ID)                                                AS deals_as_of_today,
    SUM(IFF(s.CREATED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())
            AND (s.CLOSED_AT_UTC IS NULL OR s.CLOSED_AT_UTC > DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())),
            s.FLEX_UNIT_COUNT, 0))                                                  AS units_as_of_n_days_ago,
    COUNT(DISTINCT IFF(s.CREATED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())
            AND (s.CLOSED_AT_UTC IS NULL OR s.CLOSED_AT_UTC > DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())),
            s.OPPORTUNITY_ID, NULL))                                                AS deals_as_of_n_days_ago
FROM target_months tm
JOIN scoped s ON DATE_TRUNC('month', s.ANTICIPATED_GO_LIVE_AT_UTC) = tm.target_month
GROUP BY 1, 2
ORDER BY 1, 2;
