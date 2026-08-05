-- Rolled-Out Units, Daily Trend -- Kevin: "do we not have a table that shows running rolled
-- out units? so we can see change on the daily?" Answer: not yet, this is that table.
--
-- GROSS ADDS ONLY, NOT A TRUE NET -- checked live before building this: there's no day-level
-- deactivation date on PROPERTY_BP_MONTH_STATS, only a BP-month IS_DEACTIVATED flag with no
-- date attached to it. So a true daily "net change" (adds minus deactivations) genuinely can't
-- be built at day grain -- deactivation timing just isn't tracked that precisely. This shows
-- daily GROSS new + recaptured rollouts (ROLLOUT_DATE) -- real, validated day-level data (see
-- rolled_out_units_headline.sql's header for the discovery) -- and a running cumulative sum
-- WITHIN the lookback window, not a reconstruction of total network stock. Don't bind
-- `cumulative_units` to anything that implies "total units in the network" -- for that, use
-- rolled_out_units_cube.sql's integrated_total_units (the real stock, BP-month grain). This is
-- "how many units have rolled out since the window started," a different, narrower question.
--
-- NEW vs. RECAPTURED SPLIT (added 2026-07-29) -- Kevin wants this as a stacked bar. Checked
-- live before building it: IS_NEW_INTEGRATED and (IS_RECAPTURED_NEW_ROLLOUT OR
-- IS_RECAPTURED_OTHER) are CLEANLY DISJOINT (confirmed live, zero overlap) -- safe to stack
-- without double-counting. Deliberately did NOT use IS_NEW_ROLLOUT for the "new" side even
-- though that's the more literally-named flag -- checked live, IS_NEW_ROLLOUT-and-not-
-- recaptured totals slightly MORE than IS_NEW_INTEGRATED (251,856 vs 249,564 in one month,
-- ~1% gap, likely Embed-enrolled-but-not-DI rollouts) -- using IS_NEW_INTEGRATED for "new"
-- keeps this chart's numbers reconciling exactly with rolled_out_units_cube.sql and
-- rolled_out_units_headline.sql's already-shipped headline figures, which both use
-- IS_NEW_INTEGRATED. `total_units` = new_units + recaptured_units, safe to sum since disjoint.
--
-- NO MORE MISSING DAYS -- Kevin: "why are some of the dates missing? fill those all in."
-- Previous version relied on Superblocks' chart component to fill gaps -- it didn't. Fixed at
-- the SQL level instead with an explicit date spine (GENERATOR) covering every day in
-- {{ LookbackDays.value }}, LEFT JOINed to the real data -- every day now returns a row, 0s
-- and all, regardless of what the charting library does with missing categories.
--
-- REAL DATA IS SPIKY, NOT SMOOTH -- validated live: most days show a few thousand units from
-- a few hundred properties, but 2026-07-24 alone shows 36,832 new + 1,492 recaptured units --
-- a single large portfolio activation, not an anomaly to smooth over.
--
-- Same DSMB exclusion, segment_bucket/team_bucket mapping, and filters as
-- rolled_out_units_cube.sql -- stays consistent with every other rolled-out-units view.
--
-- 7-DAY TRAILING AVERAGE (added 2026-07-30) -- Kevin: "can we add like a avg line? or should
-- it be a trending avg? basically a way of knowing if we had a decent day or not." A flat
-- average over the whole window would get dragged around by the same spikes the header above
-- already documents (one 36K-unit day from a single portfolio activation) -- not a stable
-- baseline for "was today decent." A 7-day TRAILING average instead: smooths day-to-day/
-- weekday noise (this data visibly has a weekly rhythm -- some days near zero) while still
-- reacting to a real multi-day acceleration or slowdown, unlike a single flat number for the
-- whole period. `rolling_avg_7d` computed here in SQL rather than left to Superblocks, same
-- principle as `cumulative_units` already being server-computed -- one source of truth for the
-- math, not reimplemented client-side.
--
-- WEEKENDS EXCLUDED, BUSINESS DAYS ONLY (added 2026-08-05) -- Kevin: "can we remove weekends?
-- and make the 7 day trending avg just looks at biz days." `date_spine` now filters out
-- Saturday/Sunday (`DAYOFWEEK(day) NOT IN (0, 6)` -- confirmed live, Snowflake's DAYOFWEEK is
-- 0=Sunday...6=Saturday, not ISO). This is a genuinely clean fix for BOTH asks at once, not
-- two separate changes: `rolling_avg_7d`'s window (`ROWS BETWEEN 6 PRECEDING AND CURRENT ROW`)
-- counts ROWS, not calendar days -- once weekend rows no longer exist in the result set at
-- all, that same window automatically becomes a 7-BUSINESS-day average with no change to the
-- window function itself. `{{ LookbackDays.value }}` still means calendar days back (the
-- window boundary, unchanged) -- weekends inside that window are dropped from what's shown,
-- not backfilled with extra weekdays to compensate, so a "30 day" lookback now surfaces
-- ~21-22 bars, not 30.

WITH date_spine AS (
    SELECT day FROM (
        SELECT DATEADD(day, SEQ4(), DATEADD(day, -{{ LookbackDays.value }}, CURRENT_DATE())) AS day
        FROM TABLE(GENERATOR(ROWCOUNT => {{ LookbackDays.value }} + 1))
    )
    WHERE DAYOFWEEK(day) NOT IN (0, 6)
),
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    WHERE s.ROLLOUT_DATE IS NOT NULL
      AND (s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER)
),
daily AS (
    SELECT
        b.ROLLOUT_DATE                                                              AS day,
        SUM(IFF(b.IS_NEW_INTEGRATED, b.PROPERTY_UNIT_COUNT, 0))                     AS new_units,
        SUM(IFF(b.IS_RECAPTURED_NEW_ROLLOUT OR b.IS_RECAPTURED_OTHER, b.PROPERTY_UNIT_COUNT, 0)) AS recaptured_units,
        COUNT(*)                                                                     AS properties
    FROM base b
    LEFT JOIN pmc_size p ON b.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND b.segment_bucket IS NOT NULL
      AND b.ROLLOUT_DATE >= DATEADD(day, -{{ LookbackDays.value }}, CURRENT_DATE())
      {{#Team.value}}     AND b.team_bucket = '{{Team.value}}'       {{/Team.value}}
      {{#Segment.value}}  AND b.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
      {{#Msp.value}}       AND b.PMS = '{{Msp.value}}'                {{/Msp.value}}
      {{#DealType.value}}  AND b.HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
    GROUP BY 1
)
SELECT
    ds.day,
    COALESCE(d.new_units, 0)                                             AS new_units,
    COALESCE(d.recaptured_units, 0)                                      AS recaptured_units,
    COALESCE(d.new_units, 0) + COALESCE(d.recaptured_units, 0)           AS total_units,
    COALESCE(d.properties, 0)                                            AS properties,
    SUM(COALESCE(d.new_units, 0) + COALESCE(d.recaptured_units, 0)) OVER (ORDER BY ds.day) AS cumulative_units,
    AVG(COALESCE(d.new_units, 0) + COALESCE(d.recaptured_units, 0))
        OVER (ORDER BY ds.day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)                     AS rolling_avg_7d
FROM date_spine ds
LEFT JOIN daily d ON ds.day = d.day
ORDER BY ds.day;
