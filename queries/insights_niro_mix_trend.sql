-- Integrated vs. NIRO Mix Trend -- Kevin, building on the new NIRO cube: "maybe an
-- integrated vs non integrated mix trend call out -- if non-integrated units is a bigger
-- share a few months in a row might want to call that out bc integrated units are more
-- valuable to us." Same partitioned gaps-and-islands streak technique as the other 8 scanners
-- in this repo, applied to NIRO's share of (integrated + NIRO) total.
--
-- DIRECTION MATTERS HERE -- unlike insights_mix_shift_scanner.sql (a neutral mix shift, both
-- directions surface), a RISING NIRO share is the one flag worth surfacing (chg_sign = 1) --
-- same "direction matters" logic as insights_net_units_bridge.sql Part C's churn-rising
-- streak, not the direction-agnostic mix-shift files. Integrated units are the more valuable
-- side of this mix (see docs/superblocks-setup.md §4.13 -- Strategic Value Hierarchy), so a
-- FALLING NIRO share is good news, not a comparably-weighted flag the way New Logo vs.
-- Expansion mix is.
--
-- STOCK, NOT FLOW -- same two-stage aggregation as niro_units_cube.sql (aggregate to real
-- BP_MONTH grain first, THEN roll up to the requested period via MAX_BY(value, BP_MONTH)) --
-- niro_units and integrated_total_units are both per-BP_MONTH snapshots; summing them across
-- a Quarter's 3 months would triple-count, the exact bug caught and fixed in the cube this
-- file is built on top of.
--
-- Same DSMB exclusion (pmc_size, current live PMC total > 750) as every file in this repo.
-- No departed-rep exclusion here -- this is a segment/team AGGREGATE share, not a rep-
-- attributed metric, same convention as insights_net_units_bridge.sql's segment-level parts.
--
-- MATERIALITY FLOOR: {{ MinTotalUnitsFloor.value }} on (niro + integrated) combined units --
-- default 10,000, same floor already validated for team/segment scanners in
-- insights_declining_streaks.sql. Checked live at a much lower floor (1,000) and got the
-- identical result set (MM/Ent 7-month rising streak, House Accounts 3-month) -- confirms
-- these are real, not floor-dependent noise, and 10,000 isn't silently hiding anything.
--
-- Month/Quarter {{ Granularity.value }} toggle built in from the start.

-- Part A: segment-level NIRO share, rising streak.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT
        BP_MONTH, segment_bucket,
        SUM(IFF(IS_ENGAGED AND NOT HAS_PAYMENT_INTEGRATION, ENGAGED_UNITS, 0)) AS niro_units,
        SUM(IFF(IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))                  AS integrated_total_units
    FROM scoped
    WHERE segment_bucket IS NOT NULL
    GROUP BY 1, 2
),
period_stock AS (
    SELECT
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', BP_MONTH), BP_MONTH) AS period,
        segment_bucket,
        MAX_BY(niro_units, BP_MONTH)             AS niro_units,
        MAX_BY(integrated_total_units, BP_MONTH) AS integrated_total_units
    FROM monthly_stock
    GROUP BY 1, 2
),
monthly AS (
    SELECT period, segment_bucket,
        DIV0(niro_units, niro_units + integrated_total_units) AS niro_share,
        niro_units + integrated_total_units AS total_units
    FROM period_stock
    HAVING total_units >= {{ MinTotalUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(niro_share - LAG(niro_share) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_period, MAX_BY(niro_share, period) AS latest_niro_share
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_period = MAX(latest_period) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, streak_len AS streak_periods, latest_period, ROUND(latest_niro_share, 4) AS latest_niro_share
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_periods DESC;

-- Part B: team-level NIRO share, rising streak. Same technique, PARTITION BY team_bucket.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT
        BP_MONTH, team_bucket,
        SUM(IFF(IS_ENGAGED AND NOT HAS_PAYMENT_INTEGRATION, ENGAGED_UNITS, 0)) AS niro_units,
        SUM(IFF(IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))                  AS integrated_total_units
    FROM scoped
    WHERE team_bucket IS NOT NULL
    GROUP BY 1, 2
),
period_stock AS (
    SELECT
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', BP_MONTH), BP_MONTH) AS period,
        team_bucket,
        MAX_BY(niro_units, BP_MONTH)             AS niro_units,
        MAX_BY(integrated_total_units, BP_MONTH) AS integrated_total_units
    FROM monthly_stock
    GROUP BY 1, 2
),
monthly AS (
    SELECT period, team_bucket,
        DIV0(niro_units, niro_units + integrated_total_units) AS niro_share,
        niro_units + integrated_total_units AS total_units
    FROM period_stock
    HAVING total_units >= {{ MinTotalUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(niro_share - LAG(niro_share) OVER (PARTITION BY team_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY team_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY team_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT team_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_period, MAX_BY(niro_share, period) AS latest_niro_share
    FROM with_group
    GROUP BY team_bucket, grp, chg_sign
    QUALIFY latest_period = MAX(latest_period) OVER (PARTITION BY team_bucket)
)
SELECT team_bucket, streak_len AS streak_periods, latest_period, ROUND(latest_niro_share, 4) AS latest_niro_share
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_periods DESC;
