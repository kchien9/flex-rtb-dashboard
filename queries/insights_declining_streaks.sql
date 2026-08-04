-- Declining Streaks -- Kevin, on the first Debrief macro pass: "SMB team is trending
-- downward, with 3 straight months of declining output... entrata msp pipeline is drying
-- up... this is super basic compared to what this could be." Two proactive scanners, both
-- generalizing an already-validated gaps-and-islands streak technique
-- (ai_summary_facts.sql's Part E, shout_outs_facts.sql's leader streak) by adding a
-- partition key so EVERY entity is scanned at once, not just whichever single Team/MSP
-- happens to be the current filter -- same "scan everything, only surface what crosses a
-- threshold" principle as insights_trend_flags.sql, just extended from a single-period delta
-- to a multi-month streak.
--
-- WHY A NEW FILE, NOT A PART E EXTENSION -- Part E computes ONE company-or-single-team series
-- (Expansion SHARE, a mix question). These scan MULTIPLE entities at once for a decline in
-- raw VOLUME (Part A) or pipeline COUNT (Part B) -- different question, different partition
-- shape -- kept separate rather than overloading Part E with a second grain.
--
-- MATERIALITY FLOOR, VALIDATED LIVE -- pulled 8 months of real team-level units before writing
-- this: Dana's Team's earliest 2 months (763, 552 units) are a real ramp-up/near-zero
-- artifact, not a meaningful trend -- a naive streak detector would happily call a 552->763
-- move "up 38%" and count it toward a streak. `{{ MinUnitsFloor.value }}` (default 10000,
-- comfortably below every real team-month seen live -- Rory's Team's smallest real month was
-- ~30K -- comfortably above Dana's ramp-period noise) excludes any month that doesn't clear
-- this floor from streak consideration entirely, same principle as insights_trend_flags.sql's
-- `units_prior >= 20`.
--
-- ONLY DECLINING STREAKS SURFACE, NOT RISING ONES -- deliberate: this file's whole job is the
-- "something needs attention" scan. A rising streak is good news, which is already Shout
-- Outs' / the Macro Trends headline's job to celebrate -- this file doesn't duplicate that.
--
-- DSMB EXCLUDED (Part A, standard pmc_size join) -- Part B (deal-grain MSP pipeline) has no
-- account-size concept the same way (see new_opportunities_by_msp.sql's own reasoning),
-- excluded via the standard legacy-HubSpot-record filter instead.

-- Part A: team decline streak, rolled-out units, all 4 AE pods scanned at once.
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
        SUM(IFF(s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING team_bucket IS NOT NULL AND units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(units - LAG(units) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH) AS prev_sign
    FROM with_change
    WHERE chg_sign IS NOT NULL
),
with_group AS (
    SELECT *,
        SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY team_bucket ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    SELECT team_bucket, chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX(units) AS latest_units
    FROM with_group
    GROUP BY team_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY team_bucket)
)
SELECT team_bucket, streak_len AS declining_streak_months, latest_month, latest_units
FROM streaks
WHERE chg_sign = -1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY declining_streak_months DESC;

-- Part B: MSP pipeline-created decline streak, all MSPs scanned at once. Same ingredients as
-- new_opportunities_by_msp.sql (PARTNER_MANAGEMENT_SOFTWARE + CREATED_AT_UTC, legacy-HubSpot-
-- record exclusion via OPPORTUNITY_ID LIKE '006%'), extended with a month dimension and the
-- same streak technique as Part A. Materiality floor here is on DEAL COUNT, not units (a
-- single-deal MSP is too thin a sample for "drying up" to mean anything).
--
-- BUG CAUGHT VALIDATING LIVE 2026-08-04 -- first draft bucketed by DATE_TRUNC('month',
-- CREATED_AT_UTC), a CALENDAR month -- the exact same bug class as the "Funnel Diagnosis"
-- widget incident (§4.5/§4.10 docs), just reintroduced here by accident. Every single MSP
-- showed a "decline" (e.g. Entrata 92 -> 7, Yardi 232 -> 12) purely because calendar-August
-- had only 4 days of data compared to a full July -- confirmed live by rebucketing to BP month
-- (the standard `IFF(DAY(...) <= 4, ...)` formula used everywhere else in this repo): Entrata's
-- real Aug BP month (Jul 5-Aug 4) is 86 deals, squarely in its normal 60-115/month range, not a
-- collapse at all. Fixed by bucketing `CREATED_AT_UTC` into a proper BP month before grouping.
WITH monthly AS (
    SELECT
        COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set') AS msp,
        IFF(DAY(o.CREATED_AT_UTC) <= 4, DATE_TRUNC('month', o.CREATED_AT_UTC), DATE_TRUNC('month', DATEADD(month, 1, o.CREATED_AT_UTC))) AS mo,
        COUNT(*) AS pipeline_created_deals
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    WHERE o.OPPORTUNITY_ID LIKE '006%'
      AND o.CREATED_AT_UTC >= DATEADD(month, -12, IFF(DAY(CURRENT_DATE()) <= 4, DATE_TRUNC('month', CURRENT_DATE()), DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))))
    GROUP BY 1, 2
    HAVING pipeline_created_deals >= {{ MinDealsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(pipeline_created_deals - LAG(pipeline_created_deals) OVER (PARTITION BY msp ORDER BY mo)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY msp ORDER BY mo) AS prev_sign
    FROM with_change
    WHERE chg_sign IS NOT NULL
),
with_group AS (
    SELECT *,
        SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY msp ORDER BY mo) AS grp
    FROM with_lag
),
streaks AS (
    SELECT msp, chg_sign, COUNT(*) AS streak_len, MAX(mo) AS latest_month, MAX(pipeline_created_deals) AS latest_deals
    FROM with_group
    GROUP BY msp, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY msp)
)
SELECT msp, streak_len AS declining_streak_months, latest_month, latest_deals
FROM streaks
WHERE chg_sign = -1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY declining_streak_months DESC;
