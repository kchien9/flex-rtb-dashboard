-- Forecast Decline Drivers -- Kevin: "layer in pipeline/activities into the top box - if
-- forecasting less units next month, could be attributed to less SDR pipeline or AE
-- execution." Feeds Box 1's persistent General Business Summary (see docs/superpowers/specs/
-- 2026-08-05-debrief-restructure-design.md).
--
-- TRIGGER: reuses insights_forward_pipeline_trend.sql Part C's already-validated forecast-
-- decline flag as-is -- no changes to that file's as-of-cohort logic (the technique that
-- avoids comparing a still-growing forecast against a settled actual, which would mechanically
-- read as "declining" every month by construction). Part C's own output has no column
-- literally named `segment_bucket` -- the segment attribution lives in `driver_segment` (the
-- single largest-negative-contributor segment for that target_month, already Part C's own
-- pre-computed pick) -- this file's `decline` CTE aliases that column to `segment_bucket` for
-- the join, it does not re-derive or rename anything inside Part C's pasted body itself.
--
-- CANDIDATE DRIVERS CHECKED FOR THE SAME WINDOW AS THE DECLINE, NEVER A LAGGED CLAIM:
--   1. SDR-sourced pipeline creation (sdr_funnel_by_segment.sql's `pipeline` CTE) -- did New
--      Logo pipeline creation also drop this period?
--   2. AE execution basket, checked independently, report whichever actually moved:
--      - Win rate (closed_lost_rate_cube.sql, Dimension.value='segment_bucket')
--      - Cycle time (insights_cycle_time_trend.sql Part A)
--      - Stage velocity (insights_stage_velocity.sql Part A, Stage='Negotiation')
--
-- FRAMING IS LOCKED: "coincided with," never "caused by." sdr_activity_to_pipeline.sql already
-- tested a one-month-lag causal claim for the SDR/pipeline relationship specifically and found
-- it weaker or negative in every segment -- same-period co-movement is the only claim this
-- file is allowed to make. If NONE of the 4 candidates moved unfavorably in the same window as
-- a real decline, this file returns the decline row with all 4 candidate flags FALSE --
-- narration must say "no clear driver identified this period," not invent one.
--
-- WHY THE JOIN IS SEGMENT-ONLY, NOT ALSO ON A SHARED PERIOD -- the single most important
-- structural decision in this file, worth stating plainly. `decline`'s `target_month` is
-- ALWAYS a future month (Part C's own `target_months` CTE starts at next-month, never the
-- current one) -- it's a forward forecast reassessed today. The 4 candidate checks are the
-- opposite: backward-looking actuals (SDR pipeline created, deals actually closed, deals that
-- actually transitioned stage) that can only ever have data for PAST/completed periods. A
-- literal `target_month = target_month` join between a forecast for e.g. Jan 2027 and
-- historical activity data would therefore NEVER match anything, by construction -- every
-- candidate flag would always render FALSE/NULL regardless of what's actually happening,
-- which would make "no clear driver identified" impossible to ever disprove and this whole
-- file decorative. Instead, each candidate CTE resolves to its own single LATEST FULLY-
-- ELAPSED period per segment (see next note) plus that period's own prior-period LAG, and the
-- final join matches on `segment_bucket` alone -- "as of right now (the same moment the
-- decline was detected), did this segment's most recent real SDR-pipeline/win-rate/cycle-time/
-- stage-velocity movement also go the wrong way." Each check's own resolved period is exposed
-- as its own column (`sdr_pipeline_check_month`/`win_rate_check_period`/
-- `cycle_time_check_period`/`stage_velocity_check_quarter`) precisely so a reader (or the LLM
-- narration) can see how current/stale that comparison actually is, never asserted blind.
--
-- "LATEST FULLY-ELAPSED PERIOD," NOT "LATEST ROW" -- a second real bug caught and fixed while
-- building this: naively taking each check's most-recent row would almost always mean the
-- still-in-progress current calendar month/quarter, which mechanically has fewer accumulated
-- events than a completed period purely because fewer days have elapsed -- the exact
-- "mechanically reads as decline by construction" trap this repo's own censoring conventions
-- exist to prevent (same class as `closed_lost_rate_cube.sql`'s FULLY-ELAPSED-MONTHS-ONLY
-- fix). `sdr_pipeline_check` and `cycle_time_check` explicitly drop the in-progress current
-- month before picking "latest." `win_rate_check` inherits `closed_lost_rate_cube.sql`'s own
-- already-correct current-month exclusion. `stage_velocity_check` inherits
-- `insights_stage_velocity.sql` Part A's own already-correct current-quarter exclusion.
--
-- TWO REAL BUGS FOUND AND FIXED LIVE 2026-08-06 IN THE 4 SOURCE FILES THEMSELVES, NOT JUST
-- HERE -- caught while validating this file, fixed at the source per this session's standing
-- "fix real bugs wherever found" rule (same precedent as Task 7's pipeline_cube.sql fix):
--   1. `insights_stage_velocity.sql` Part A used `QUALIFY entered_q < DATE_TRUNC('quarter',
--      CURRENT_DATE())` with NO window function anywhere in that query -- confirmed live, this
--      is a hard Snowflake compile error ("found QUALIFY clause but no window function"), so
--      Part A as originally committed could never actually run. Fixed there to `HAVING
--      entered_q < ...` (correct syntax for filtering a GROUP BY output column
--      post-aggregation). This file's `stage_velocity_check` CTE pastes the CORRECTED version.
--   2. `sdr_funnel_by_segment.sql` and `insights_cycle_time_trend.sql` each had literal
--      semicolons inside header prose (3 in the former, 2 in the latter) -- the exact
--      "naive multi-statement splitter" bug docs/superblocks-setup.md 4.18 already documented
--      catching twice elsewhere, apparently missed on these 2 files. Fixed at the source (--
--      replacing the semicolons), not just avoided here.
--
-- SEGMENT TAXONOMY MISMATCH -- STAGE VELOCITY IS THE ONE CHECK WITH REAL, DOCUMENTED, LIMITED
-- COVERAGE -- `decline`, `sdr_pipeline_check`, `win_rate_check`, and `cycle_time_check` all
-- share the same 3-real-segment taxonomy (MM/Ent, Strategic, SMB, everything else falling to
-- NULL/Not Set). `insights_stage_velocity.sql` uses a DIFFERENT, intentional 3-way taxonomy
-- (SMB / DSMB / Strategic-MM -- Strategic and MM/Ent are pooled into one "Strategic/MM"
-- bucket, and there's a whole separate DSMB bucket the other 3 checks don't have at all). This
-- file does NOT invent a fake remapping between the two taxonomies -- that would misrepresent
-- data that doesn't actually correspond 1:1. The literal string join means
-- `stage_velocity_check` can only ever match when `driver_segment = 'SMB'` exactly -- a decline
-- driven by 'Strategic' or 'MM/Ent' will always show `stage_velocity_worsened = FALSE` with a
-- NULL `avg_days_in_stage` -- a real coverage gap, not a bug, and not silently papered over
-- (the NULL columns make the gap visible to narration, which should say "no stage-velocity
-- data available for this segment," not blend it into "no decline").
--
-- 'Not Set' DRIVER_SEGMENT IS THE SAME KIND OF GAP AS THE STAGE-VELOCITY ONE ABOVE -- Part C's
-- own `scoped` CTE COALESCEs an unattributed owner to the literal string 'Not Set', so
-- `driver_segment` (and therefore this file's `segment_bucket`) CAN be 'Not Set'. None of the
-- 4 checks' own segment CASE expressions ever produce that string -- each one falls to NULL
-- for an unmapped team and gets removed by that check's own `WHERE ... IS NOT NULL` (or
-- equivalent) before this file ever sees it. So a decline attributed to 'Not Set' will always
-- join to zero rows across all 4 checks, by construction -- every flag renders FALSE with NULL
-- underlying values, which looks identical to "checked all 4 and none moved unfavorably" even
-- though no check actually ran. Same treatment as the stage-velocity coverage gap above:
-- narration seeing a 'Not Set' `segment_bucket` alongside all-NULL check columns should say
-- "no driver data available for this decline (unattributed segment)," not "no clear driver
-- identified" -- the two phrasings mean different things and this file's own NULL columns are
-- what let a reader tell them apart.
--
-- STAGE FILTER LOCKED TO 'Negotiation', NOT USER-SELECTABLE -- insights_stage_velocity.sql
-- Part A covers 4 stages (Qualification/Discovery/Building Value/Negotiation) -- pulling all 4
-- would produce multiple rows per segment/quarter (fan-out against this file's single-row-
-- per-segment join). Negotiation was picked because it's the stage this repo's own stuck-deal
-- watch list (Part B of that file) already treats as the flagship signal for AE execution
-- problems, not an arbitrary pick.
--
-- WIN RATE'S TEAM-GRAIN FAN-OUT -- caught and fixed while building: closed_lost_rate_cube.sql
-- groups by (period, segment_bucket, team_bucket, slice), and `team_bucket` is a FINER grain
-- than `segment_bucket` (SMB alone splits into Sebastian's Team / Rory's Team / NULL) --
-- pasting that body in and selecting straight from it would return multiple rows per
-- (period, segment_bucket) for SMB, breaking this file's one-row-per-segment join. Fixed by
-- re-aggregating to pure (period, segment_bucket) grain from the raw `units_lost`/
-- `total_closed_units` columns already in the pasted body (SUM the numerator and denominator
-- separately, THEN divide) -- never averaging the pre-computed per-team rate directly, which
-- would weight every team equally regardless of volume and misstate the real segment-level
-- rate.
--
-- Dimension.value hardcoded to 'segment_bucket' (this file only ever needs the segment cut,
-- per the plan) and Granularity.value hardcoded to 'Month' (this file's `target_month`/
-- `latest_period` join key is month-grain throughout -- Quarter grain would break period
-- comparability against `decline`'s month-grain target). `{{ LookbackMonths.value }}` is
-- shared across `sdr_pipeline_check`/`win_rate_check`/`stage_velocity_check` deliberately, not
-- an oversight -- it answers "how far back do we look to establish each check's own trend,"
-- and using one shared control keeps every candidate looking at a consistent window, matching
-- this file's own "same window" framing rule. `{{ GraceMonths.value }}` is still a required,
-- real bound param (an empty Mustache substitution is a SQL syntax error, same gotcha
-- documented in docs/superblocks-setup.md 4.16/4.18) even though it's functionally inert here
-- -- `win_rate_check`'s departed-rep grace check only ever bites when Dimension.value='rep',
-- which this file never sets.
--
-- LIVE VALIDATION FINDING (2026-08-06) -- with the real current-day default window
-- (TargetMonthsAhead=3), Sept/Oct/Nov 2026 all show a POSITIVE company-wide pipeline change
-- (+22.7%/+27.5%/+5.8%) -- zero decline rows, confirmed by design, not a bug (this file has
-- nothing to attribute when there's no real decline). Widening to 18 months ahead surfaces
-- exactly ONE real decline in the entire live dataset: target_month=2027-01, company_pct_
-- change=-94.9% (total_units_n_days_ago 123,000 -> total_units_today 6,266), driver_segment=
-- 'Strategic' -- every other month from Feb 2027 onward has zero open-pipeline rows at all
-- (pipeline this far out is simply too thin to compute a ratio against). For that one real
-- row: sdr_pipeline_declined=TRUE (July 2026 Strategic pipeline_created=2 vs June=4, cross-
-- checked live against sdr_funnel_by_segment.sql directly -- exact match), win_rate_declined=
-- FALSE (loss rate improved, 4.25% vs 28.79% prior), cycle_time_worsened=FALSE (median touch-
-- to-close improved, 2.5 days vs 124 -- Strategic's low deal volume means this check's latest
-- qualifying month is March 2026, several months stale, exposed via `cycle_time_check_period`
-- rather than hidden), stage_velocity_worsened=FALSE with NULL underlying values (the SMB-only
-- coverage gap above -- 'Strategic' never matches 'Strategic/MM'). 3 of 4 flags resolving
-- FALSE with real, non-degenerate numbers on this row demonstrates the flag logic isn't
-- mechanically TRUE by construction -- the current live dataset does not happen to contain a
-- second real decline row to also demonstrate all 4 FALSE simultaneously (there is exactly one
-- real decline row in the dataset today, full stop) -- real data permitting, per the plan's
-- own caveat.

WITH decline AS (
    -- insights_forward_pipeline_trend.sql Part C, pasted verbatim below (its full CTE chain
    -- and final SELECT, unmodified) -- only this wrapper's outer SELECT renames columns for
    -- the join, per the note above.
    SELECT
        target_month,
        driver_segment AS segment_bucket,
        company_pct_change,
        driver_segment_pct_change,
        driver_segment_unit_delta
    FROM (
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
            -- the segment contributing the single largest NEGATIVE unit delta -- Kevin's own
            -- example ("strategic segment was driver w 50% less units")
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
        -- materiality floor: only surface a real decline on a base big enough to matter --
        -- validate this default against real distribution before treating it as final
        WHERE cw.total_units_n_days_ago >= {{ MinUnitsFloor.value }}
          AND cw.pct_change <= -{{ MinPctDeclineThreshold.value }}
        ORDER BY cw.target_month
    )
    WHERE company_pct_change < 0  -- only real declines are candidates for driver attribution
),
sdr_pipeline_check AS (
    -- sdr_funnel_by_segment.sql's `pipeline` CTE (New Logo pipeline created, by AE segment),
    -- pasted verbatim below, plus only the CTEs it actually depends on (`months`/`pmc_size`/
    -- `user_dedup`) -- not this file's other CTEs (activity/meetings), which this check
    -- doesn't need. In-progress current month excluded before picking "latest" (see header).
    SELECT
        segment,
        mo AS latest_month,
        pipeline_created,
        LAG(pipeline_created) OVER (PARTITION BY segment ORDER BY mo) AS pipeline_created_prior
    FROM (
        WITH months AS (
            SELECT DATEADD(month, -SEQ4(), DATE_TRUNC('month', CURRENT_DATE())) AS mo
            FROM TABLE(GENERATOR(ROWCOUNT => {{ LookbackMonths.value }} + 1))
        ),
        pmc_size AS (
            SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
            FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
            WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
              AND IS_IN_NETWORK
            GROUP BY 1
        ),
        user_dedup AS (
            SELECT EMAIL, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
            FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
            QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
        )
        SELECT
            mo.mo, e.ae_segment AS segment,
            COUNT(DISTINCT o.OPPORTUNITY_ID) AS pipeline_created
        FROM months mo
        JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o
            ON DATE_TRUNC('month', o.CREATED_AT_UTC) = mo.mo
           AND o.OPPORTUNITY_TYPE = 'New Logo'
        LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY oe ON o.OWNER_SK = oe.EMPLOYEE_SK AND oe.IS_CURRENT = TRUE
        LEFT JOIN user_dedup ou ON ou.EMAIL = oe.EMAIL
        LEFT JOIN (
            SELECT EMAIL,
                CASE
                    WHEN TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                    WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
                    WHEN TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                    ELSE NULL
                END AS ae_segment
            FROM user_dedup
        ) e ON e.EMAIL = ou.EMAIL
        LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
        LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
        WHERE e.ae_segment IS NOT NULL
          AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
        GROUP BY 1, 2
    )
    WHERE mo < DATE_TRUNC('month', CURRENT_DATE())
    QUALIFY ROW_NUMBER() OVER (PARTITION BY segment ORDER BY mo DESC) = 1
),
win_rate_check AS (
    -- closed_lost_rate_cube.sql, Dimension.value hardcoded to 'segment_bucket' and
    -- Granularity.value hardcoded to 'Month' (see header), pasted verbatim below. Re-aggregated
    -- to pure (period, segment_bucket) grain immediately above the LAG (see header's team-
    -- grain fan-out note) -- the LAG and "latest period" selection operate on that
    -- re-aggregated rate, not on the pasted body's own row grain.
    SELECT
        segment_bucket,
        period AS latest_period,
        loss_rate_by_units,
        LAG(loss_rate_by_units) OVER (PARTITION BY segment_bucket ORDER BY period) AS loss_rate_prior
    FROM (
        SELECT period, segment_bucket,
            SUM(units_lost) AS units_lost, SUM(total_closed_units) AS total_closed_units,
            DIV0(SUM(units_lost), SUM(total_closed_units)) AS loss_rate_by_units
        FROM (
            WITH pmc_size AS (
                SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
                FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
                WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
                  AND IS_IN_NETWORK
                GROUP BY 1
            ),
            user_dedup AS (
                SELECT FULL_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
                FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
                QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
            ),
            scoped AS (
                SELECT
                    o.*,
                    e.FULL_NAME AS rep,
                    cr.IS_ACTIVE, cr.LAST_LOGIN_AT_UTC,
                    CASE
                        WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                        WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
                        WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                        ELSE NULL
                    END AS segment_bucket,
                    CASE
                        WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
                        WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
                        WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
                        WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
                        ELSE NULL
                    END AS team_bucket,
                    COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set') AS msp,
                    o.OPPORTUNITY_TYPE AS deal_type
                FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
                LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
                    ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE AND e.SOURCE_SYSTEM = 'salesforce'
                LEFT JOIN user_dedup cr ON cr.FULL_NAME = e.FULL_NAME
                LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
                LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
                WHERE o.IS_CLOSED
                  AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
                  AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())
                  AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }} * 1, DATE_TRUNC('month', CURRENT_DATE()))
                  AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
                  -- departed-rep grace check: only bites when slicing by rep -- this file
                  -- always slices by segment_bucket, so this is a permanent no-op here, kept
                  -- verbatim for fidelity to the source file (see header re: GraceMonths)
                  AND (NOT ('segment_bucket' = 'rep') OR cr.FULL_NAME IS NULL OR cr.IS_ACTIVE
                       OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
            )
            SELECT
                DATE_TRUNC('month', CLOSED_AT_UTC) AS period,
                segment_bucket,
                team_bucket,
                COALESCE(segment_bucket, 'Not Set') AS slice,
                COUNT(*) AS total_closed_deals,
                SUM(IFF(IS_CLOSED_WON, 1, 0)) AS deals_won,
                SUM(IFF(NOT IS_CLOSED_WON, 1, 0)) AS deals_lost,
                SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0)) AS total_closed_units,
                SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)) AS units_lost
            FROM scoped
            WHERE segment_bucket IS NOT NULL
              {{#Team.value}}     AND team_bucket    IN ({{Team.value}})    {{/Team.value}}
              {{#Msp.value}}      AND msp            IN ({{Msp.value}})     {{/Msp.value}}
              {{#DealType.value}} AND deal_type       IN ({{DealType.value}}) {{/DealType.value}}
              {{#Rep.value}}      AND rep            IN ({{Rep.value}})     {{/Rep.value}}
            GROUP BY 1, 2, 3, 4
        )
        GROUP BY period, segment_bucket
    )
    QUALIFY ROW_NUMBER() OVER (PARTITION BY segment_bucket ORDER BY period DESC) = 1
),
cycle_time_check AS (
    -- insights_cycle_time_trend.sql Part A (New Logo touch-to-close median days, by segment),
    -- pasted verbatim below, Granularity.value hardcoded to 'Month'. In-progress current month
    -- excluded before picking "latest" (see header).
    SELECT
        segment_bucket,
        period AS latest_period,
        median_days,
        LAG(median_days) OVER (PARTITION BY segment_bucket ORDER BY period) AS median_days_prior
    FROM (
        WITH any_activity AS (
            SELECT CRM_ACCOUNT_SK, activity_date FROM (
                SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
                UNION ALL
                SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
            )
        ),
        first_activity_ever AS (
            SELECT CRM_ACCOUNT_SK, MIN(activity_date) AS first_activity_date
            FROM any_activity
            GROUP BY 1
        ),
        deals AS (
            SELECT o.OPPORTUNITY_ID, o.CRM_ACCOUNT_SK, o.CLOSED_AT_UTC,
                CASE
                    WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                    WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
                    WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                    WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
                    ELSE NULL
                END AS segment_bucket
            FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
            WHERE o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE = 'New Logo'
              AND o.CLOSED_AT_UTC >= DATEADD(month, -24, CURRENT_DATE())
        ),
        with_touch AS (
            SELECT d.OPPORTUNITY_ID, d.segment_bucket, d.CLOSED_AT_UTC,
                IFF(DAY(d.CLOSED_AT_UTC) <= 4, DATE_TRUNC('month', d.CLOSED_AT_UTC), DATE_TRUNC('month', DATEADD(month, 1, d.CLOSED_AT_UTC))) AS bp_month,
                DATEDIFF(day, fa.first_activity_date, d.CLOSED_AT_UTC) AS days_touch_to_close
            FROM deals d
            LEFT JOIN first_activity_ever fa ON d.CRM_ACCOUNT_SK = fa.CRM_ACCOUNT_SK
            WHERE d.segment_bucket IS NOT NULL AND fa.first_activity_date IS NOT NULL
        ),
        monthly AS (
            SELECT segment_bucket,
                bp_month AS period,
                MEDIAN(days_touch_to_close) AS median_days,
                COUNT(*) AS deals_with_touch
            FROM with_touch
            GROUP BY 1, 2
            HAVING deals_with_touch >= {{ MinDealsFloor.value }}
        )
        SELECT * FROM monthly
    )
    WHERE period < DATE_TRUNC('month', CURRENT_DATE())
    QUALIFY ROW_NUMBER() OVER (PARTITION BY segment_bucket ORDER BY period DESC) = 1
),
stage_velocity_check AS (
    -- insights_stage_velocity.sql Part A, Stage locked to 'Negotiation' (see header), pasted
    -- verbatim below WITH the 2026-08-06 QUALIFY-with-no-window-function fix applied (HAVING,
    -- not QUALIFY -- see header). Segment taxonomy differs from the other 3 checks -- see
    -- header's coverage-gap note.
    SELECT
        segment AS segment_bucket,
        entered_q AS latest_quarter,
        avg_days_in_stage,
        LAG(avg_days_in_stage) OVER (PARTITION BY segment ORDER BY entered_q) AS avg_days_in_stage_prior
    FROM (
        WITH segmented AS (
            SELECT
                OPPORTUNITY_ID,
                CASE
                    WHEN STATIC_TEAM_NAME LIKE 'SMB Account Executives%' OR STATIC_TEAM_NAME = 'SMB Manager' THEN 'SMB'
                    WHEN STATIC_TEAM_NAME LIKE 'Deep SMB%' OR STATIC_TEAM_NAME LIKE 'DSMB%' THEN 'DSMB'
                    WHEN STATIC_TEAM_NAME IN ('Brandon''s Team','Cory''s Team') OR STATIC_TEAM_NAME LIKE 'Strategic%' OR STATIC_TEAM_NAME LIKE 'MM/Enterprise%' THEN 'Strategic/MM'
                    ELSE NULL
                END AS segment,
                QUALIFICATION_AT_UTC, DISCOVERY_AT_UTC, BUILDING_VALUE_AT_UTC, NEGOTIATION_AT_UTC, DEAL_REVIEW_AT_UTC
            FROM FLEX.SALES.FCT_CRM_OPPORTUNITY
            WHERE CREATED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
        ),
        transitions AS (
            SELECT segment, 'Negotiation' AS stage, DATE_TRUNC('quarter', NEGOTIATION_AT_UTC) AS entered_q,
                NEGOTIATION_AT_UTC AS stage_start, DEAL_REVIEW_AT_UTC AS stage_end FROM segmented
        )
        SELECT
            segment,
            stage,
            entered_q,
            COUNT(*) AS resolved_deals,
            AVG(DATEDIFF(day, stage_start, stage_end)) AS avg_days_in_stage
        FROM transitions
        WHERE stage_start IS NOT NULL AND stage_end IS NOT NULL AND segment IS NOT NULL
          AND stage = 'Negotiation'
        GROUP BY 1, 2, 3
        HAVING entered_q < DATE_TRUNC('quarter', CURRENT_DATE())  -- drop in-progress quarter, same censoring reason as insights_stage_velocity.sql -- HAVING, not QUALIFY, see 2026-08-06 fix note in header and in that file
    )
    QUALIFY ROW_NUMBER() OVER (PARTITION BY segment ORDER BY entered_q DESC) = 1
)
SELECT
    d.target_month,
    d.segment_bucket,
    d.company_pct_change,
    -- Candidate 1: SDR pipeline also down (same window, not a lagged claim)
    sp.latest_month AS sdr_pipeline_check_month,
    IFF(sp.pipeline_created < sp.pipeline_created_prior, TRUE, FALSE) AS sdr_pipeline_declined,
    sp.pipeline_created, sp.pipeline_created_prior,
    -- Candidate 2a: win rate down (loss rate up)
    wr.latest_period AS win_rate_check_period,
    IFF(wr.loss_rate_by_units > wr.loss_rate_prior, TRUE, FALSE) AS win_rate_declined,
    wr.loss_rate_by_units, wr.loss_rate_prior,
    -- Candidate 2b: cycle time up (slower)
    ct.latest_period AS cycle_time_check_period,
    IFF(ct.median_days > ct.median_days_prior, TRUE, FALSE) AS cycle_time_worsened,
    ct.median_days, ct.median_days_prior,
    -- Candidate 2c: stage velocity slower (SMB-only literal-match coverage, see header)
    sv.latest_quarter AS stage_velocity_check_quarter,
    IFF(sv.avg_days_in_stage > sv.avg_days_in_stage_prior, TRUE, FALSE) AS stage_velocity_worsened,
    sv.avg_days_in_stage, sv.avg_days_in_stage_prior
FROM decline d
LEFT JOIN sdr_pipeline_check sp ON sp.segment = d.segment_bucket
LEFT JOIN win_rate_check wr ON wr.segment_bucket = d.segment_bucket
LEFT JOIN cycle_time_check ct ON ct.segment_bucket = d.segment_bucket
LEFT JOIN stage_velocity_check sv ON sv.segment_bucket = d.segment_bucket
ORDER BY d.target_month, d.segment_bucket;
