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
-- BUG CAUGHT AND FIXED LIVE 2026-08-05, PART B -- the first draft's `scoped` CTE filtered
-- `WHERE NOT o.IS_CLOSED` as a blanket population filter, meaning any deal that was open
-- {{ AsOfDaysAgo.value }} days ago but has SINCE closed (won or lost) got silently excluded
-- from the ENTIRE query, not just from today's slice -- confirmed live, 112 real deals in the
-- next-3-months window fit this exact pattern. This deflated BOTH as_of_today and
-- as_of_n_days_ago for that cohort, since the row never appeared in either column. Fixed:
-- `scoped` no longer pre-filters on IS_CLOSED at all -- "currently open" is applied ONLY inside
-- the as-of-today conditional aggregate, while as-of-N-days-ago uses the purely historical
-- existed-and-was-open condition regardless of what happened to the deal afterward.
-- `deals_since_closed_lost` surfaces the real-loss component of that gap explicitly.
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
-- that should actually drive a callout) -- Part B is the low-confidence leg (context only, never
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
        o.CREATED_AT_UTC, o.CLOSED_AT_UTC, o.IS_CLOSED, o.IS_CLOSED_WON,
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
    -- NOT restricted to NOT IS_CLOSED here -- see header bug note. A deal open 30 days ago
    -- that has SINCE closed (won or lost) must still count toward the as-of-N-days-ago figure --
    -- "currently open" is only the correct condition for the as-of-TODAY figure, applied below
    -- inside the conditional aggregates, not as a blanket population filter.
    WHERE o.OPPORTUNITY_TYPE != 'New Vertical'
      AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
)
SELECT
    tm.target_month,
    s.segment_bucket,
    SUM(IFF(NOT s.IS_CLOSED, s.FLEX_UNIT_COUNT, 0))                                 AS units_as_of_today,
    COUNT(DISTINCT IFF(NOT s.IS_CLOSED, s.OPPORTUNITY_ID, NULL))                    AS deals_as_of_today,
    SUM(IFF(s.CREATED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())
            AND (s.CLOSED_AT_UTC IS NULL OR s.CLOSED_AT_UTC > DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())),
            s.FLEX_UNIT_COUNT, 0))                                                  AS units_as_of_n_days_ago,
    COUNT(DISTINCT IFF(s.CREATED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())
            AND (s.CLOSED_AT_UTC IS NULL OR s.CLOSED_AT_UTC > DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())),
            s.OPPORTUNITY_ID, NULL))                                                AS deals_as_of_n_days_ago,
    -- Real signal, not noise: deals that WERE in the as-of-N-days-ago cohort but have since
    -- closed lost -- these explain part of any gap between the two columns beyond normal
    -- pipeline build. Shown separately so a real loss doesn't get buried inside a units delta.
    COUNT(DISTINCT IFF(s.CREATED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())
            AND s.CLOSED_AT_UTC > DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())
            AND s.IS_CLOSED AND NOT s.IS_CLOSED_WON,
            s.OPPORTUNITY_ID, NULL))                                                AS deals_since_closed_lost
FROM target_months tm
JOIN scoped s ON DATE_TRUNC('month', s.ANTICIPATED_GO_LIVE_AT_UTC) = tm.target_month
GROUP BY 1, 2
ORDER BY 1, 2;

-- Part C: the actual decline flag + driver, pre-computed so the LLM never does the subtraction
-- itself (same rule this file's header already states -- "don't ask an LLM to also compute
-- the numbers itself").
--
-- BUILT ON PART B (OPEN PIPELINE), NOT PART A -- a real reversal of the "Part A drives the
-- callout" framing stated above, worth explaining plainly. Part A (closed-awaiting-rollout)
-- can only ever GROW -- once a deal is IS_CLOSED_WON it never un-closes, so
-- units_as_of_n_days_ago can never exceed units_as_of_today there by construction (confirmed
-- live -- every Part A row so far has an as-of-N-days-ago of exactly 0 or less than today).
-- A real DECLINE -- the thing Kevin actually wants flagged -- can only show up on the leg
-- where deals can leave a cohort: Part B, where a deal open 30 days ago can have since closed
-- lost or gotten pushed to a different month. So despite Part B being the lower-confidence
-- leg, it's the only one that can mechanically produce the signal this feature exists to
-- catch. The narration MUST say so explicitly -- "next month's open pipeline has weakened"
-- carries real uncertainty (unweighted face value, no accuracy backing per pipeline_forecast.
-- sql's own validation), not "we're going to miss the number."
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
        o.CREATED_AT_UTC, o.CLOSED_AT_UTC, o.IS_CLOSED, o.IS_CLOSED_WON,
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
    WHERE o.OPPORTUNITY_TYPE != 'New Vertical'
      AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
),
by_segment AS (
    SELECT
        tm.target_month,
        s.segment_bucket,
        SUM(IFF(NOT s.IS_CLOSED, s.FLEX_UNIT_COUNT, 0)) AS units_today,
        SUM(IFF(s.CREATED_AT_UTC <= DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())
                AND (s.CLOSED_AT_UTC IS NULL OR s.CLOSED_AT_UTC > DATEADD(day, -{{ AsOfDaysAgo.value }}, CURRENT_DATE())),
                s.FLEX_UNIT_COUNT, 0)) AS units_n_days_ago
    FROM target_months tm
    JOIN scoped s ON DATE_TRUNC('month', s.ANTICIPATED_GO_LIVE_AT_UTC) = tm.target_month
    GROUP BY 1, 2
),
company_wide AS (
    SELECT target_month,
        SUM(units_today) AS total_units_today,
        SUM(units_n_days_ago) AS total_units_n_days_ago,
        DIV0(SUM(units_today) - SUM(units_n_days_ago), SUM(units_n_days_ago)) AS pct_change
    FROM by_segment
    GROUP BY 1
),
driver AS (
    -- the segment contributing the single largest NEGATIVE unit delta -- Kevin's own example
    -- ("strategic segment was driver w 50% less units")
    SELECT target_month, segment_bucket, units_today, units_n_days_ago,
        DIV0(units_today - units_n_days_ago, units_n_days_ago) AS segment_pct_change,
        units_today - units_n_days_ago AS segment_unit_delta
    FROM by_segment
    QUALIFY ROW_NUMBER() OVER (PARTITION BY target_month ORDER BY (units_today - units_n_days_ago) ASC) = 1
)
SELECT
    cw.target_month,
    cw.total_units_today,
    cw.total_units_n_days_ago,
    ROUND(cw.pct_change, 4) AS company_pct_change,
    d.segment_bucket AS driver_segment,
    ROUND(d.segment_pct_change, 4) AS driver_segment_pct_change,
    d.segment_unit_delta AS driver_segment_unit_delta
FROM company_wide cw
JOIN driver d ON d.target_month = cw.target_month
-- materiality floor: only surface a real decline on a base big enough to matter -- validate
-- this default against real distribution before treating it as final
WHERE cw.total_units_n_days_ago >= {{ MinUnitsFloor.value }}
  AND cw.pct_change <= -{{ MinPctDeclineThreshold.value }}
ORDER BY cw.target_month;
