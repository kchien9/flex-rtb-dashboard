-- Mix Shift Scanner -- Kevin: "trends for all major msps (mix too - not only knowing if one
-- msp is increasing or decreasing but the total mix of units across msps)... team is weighted
-- too heavily on expansion deals, push the team on new logos... new vs recaptured." Companion
-- to insights_declining_streaks.sql (which scans RAW VOLUME for a decline) -- this scans SHARE
-- (composition) for a sustained multi-month move, reusing insights_mix_shift.sql's already-
-- validated share formulas (expansion_share, recapture_share, is_recapture boolean) but
-- generalized from ONE company/team series to every entity scanned at once, via the same
-- gaps-and-islands + partition-key technique as insights_declining_streaks.sql.
--
-- WHY NOT A FIXED SKEW THRESHOLD -- tried this first, checked live before committing to it:
-- pulled 8 months of real expansion_share by team. Dana's Team (Strategic) runs 85-100%
-- Expansion most months; Brandon's Team (MM/Ent) runs 58-98%. That's their STRUCTURAL norm
-- (larger, more established accounts naturally see more expansion activity), not a risk
-- signal -- a fixed ">65% = too skewed" band would permanently flag both of them every single
-- month, which is exactly the "cry wolf" noise this repo has avoided elsewhere (materiality
-- floors, pacing-comparison bans). Fixed by using the SAME streak technique as
-- insights_declining_streaks.sql, applied to the SHARE ratio instead of raw units --
-- "expansion_share has moved the same direction for N straight months" is meaningful for any
-- team regardless of its baseline level, "expansion_share is currently above X%" is not.
--
-- BOTH DIRECTIONS SURFACE HERE, UNLIKE insights_declining_streaks.sql -- a rising Expansion
-- share isn't inherently bad (could mean strong upsell execution) and a falling one isn't
-- inherently good -- this is a MIX signal, not a decline/growth one, so both directions are
-- worth knowing about. The narration layer decides whether "shifting toward Expansion" or
-- "shifting toward New Logo" is the more actionable framing given the direction and the team's
-- history, not this query.

-- Part A: MSP share-of-total-units trend, ALL MSPs scanned at once.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT s.BP_MONTH, s.PMS, s.PROPERTY_UNIT_COUNT
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
month_totals AS (
    SELECT BP_MONTH, SUM(PROPERTY_UNIT_COUNT) AS month_total FROM base GROUP BY 1
),
monthly AS (
    SELECT COALESCE(b.PMS, 'Not Set') AS msp, b.BP_MONTH,
        DIV0(SUM(b.PROPERTY_UNIT_COUNT), mt.month_total) AS share
    FROM base b
    JOIN month_totals mt ON b.BP_MONTH = mt.BP_MONTH
    GROUP BY 1, 2, mt.month_total
    HAVING SUM(b.PROPERTY_UNIT_COUNT) >= 1000
),
with_change AS (
    SELECT *, SIGN(share - LAG(share) OVER (PARTITION BY msp ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY msp ORDER BY BP_MONTH) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY msp ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    -- MAX_BY (not the MIN-exploits-monotonicity trick used in insights_declining_streaks.sql)
    -- because this file surfaces BOTH directions, so "latest = smallest" doesn't hold here.
    SELECT msp, chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX_BY(share, BP_MONTH) AS latest_share
    FROM with_group
    GROUP BY msp, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY msp)
)
SELECT msp, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_share, 4) AS latest_share
FROM streaks
-- MAJOR MSPs ONLY -- Kevin asked for "all major MSPs," and a raw unit floor alone isn't
-- enough: AMC Rent Pay cleared the 1000-unit floor above but its actual SHARE of the total is
-- 0.37% -- a real move on an irrelevant MSP isn't a "major MSP" signal. `latest_share >= 0.02`
-- (2%) keeps the query focused on MSPs that matter to the business shape, not every minor one.
WHERE streak_len >= {{ MinStreakMonths.value }} AND latest_share >= 0.02
ORDER BY streak_months DESC;

-- Part B: New Logo vs. Expansion share streak, by TEAM -- generalizes ai_summary_facts.sql
-- Part E from a single {{ Team.value }}-filtered series to all 4 AE pods scanned at once.
-- Same "both directions surface" reasoning as Part A above -- confirmed live before writing
-- this that Dana's/Brandon's Teams structurally run 60-100% Expansion share most months
-- (larger, more established accounts), so a fixed skew threshold would flag them permanently;
-- streak-on-direction avoids that false-alarm problem entirely.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        s.BP_MONTH,
        DIV0(SUM(IFF(s.HUBSPOT_DEAL_TYPE = 'Expansion', s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS expansion_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING team_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(expansion_share - LAG(expansion_share) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    SELECT team_bucket, chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX_BY(expansion_share, BP_MONTH) AS latest_expansion_share
    FROM with_group
    GROUP BY team_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY team_bucket)
)
SELECT team_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_expansion_share, 4) AS latest_expansion_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part B-Segment: same as Part B, PARTITION BY segment_bucket instead of team_bucket --
-- SMB is 1 segment but 2 teams, so a segment-level mix shift can be real even when neither
-- individual SMB team's own streak (Part B) crosses the threshold on its own.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        s.BP_MONTH,
        DIV0(SUM(IFF(s.HUBSPOT_DEAL_TYPE = 'Expansion', s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS expansion_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(expansion_share - LAG(expansion_share) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX_BY(expansion_share, BP_MONTH) AS latest_expansion_share
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_expansion_share, 4) AS latest_expansion_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part C: New vs. Recaptured share streak, by TEAM and SEGMENT -- same technique as Part B,
-- `is_recapture` boolean copied verbatim from insights_mix_shift.sql (broader than the
-- IS_RECAPTURED_NEW_ROLLOUT/IS_RECAPTURED_OTHER pair alone -- includes the NON_INTEGRATED
-- recapture variants too, matching that file's own already-validated definition).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        s.BP_MONTH,
        DIV0(SUM(IFF(s.IS_RECAPTURED_OTHER OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_NON_INTEGRATED_RECAPTURED_OTHER OR s.IS_NON_INTEGRATED_RECAPTURED_NEW_ROLLOUT, s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS recapture_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING team_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(recapture_share - LAG(recapture_share) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    SELECT team_bucket, chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX_BY(recapture_share, BP_MONTH) AS latest_recapture_share
    FROM with_group
    GROUP BY team_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY team_bucket)
)
SELECT team_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_recapture_share, 4) AS latest_recapture_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part C-Segment: same as Part C, PARTITION BY segment_bucket.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        s.BP_MONTH,
        DIV0(SUM(IFF(s.IS_RECAPTURED_OTHER OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_NON_INTEGRATED_RECAPTURED_OTHER OR s.IS_NON_INTEGRATED_RECAPTURED_NEW_ROLLOUT, s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS recapture_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(recapture_share - LAG(recapture_share) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX_BY(recapture_share, BP_MONTH) AS latest_recapture_share
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_recapture_share, 4) AS latest_recapture_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;
