-- DEPRECATED 2026-07-30 -- Kevin: "possible departures lets just remove. they know who
-- departed." Left in place only until the Superblocks "Possible Departures / Reassignments"
-- section is unwired from it -- once that's done, delete this file. Do not build on top of
-- this query or reference it from anything new.
--
-- Possible Departures -- org-wide, DEPARTED ONLY. Replaces an unvalidated Superblocks widget
-- (2026-07-29) -- Kevin found a "Possible Departures / Reassignments" list on the Coaching tab
-- flagging reps with "0 units for 3 consecutive months," which had Cory Baach, Doron David,
-- and Morgan Giles on it -- all three are confirmed still-active, currently-producing reps
-- (checked live: real Closed Won units EVERY month for 5 straight months, no zero month at
-- all, let alone three). No query anywhere in this repo implements "0 units for N consecutive
-- months" -- that widget was built independently in Superblocks, unvalidated.
--
-- WHY A ZERO-UNITS HEURISTIC IS THE WRONG APPROACH -- units are lumpy (see performance_cube.
-- sql's header on why closed_won_units never gets a pacing comparison) -- a real, currently-
-- employed, currently-selling rep can legitimately have a slow stretch without having left.
-- Departure is a STATUS question, not an ACTIVITY-inference question -- answer it directly
-- from STG_SALESFORCE__USER's real IS_ACTIVE/LAST_LOGIN_AT_UTC (same source oneonone_prep.sql
-- already uses and Kevin already validated), deduped the same way rep_leaderboard.sql is
-- (Morgan Giles has 2 STG_SALESFORCE__USER rows, one real/active and one stale/deactivated --
-- must dedupe or a real active rep can get flagged off the wrong row).
--
-- "REASSIGNED" DELIBERATELY DROPPED -- tried building this too (compare each rep's historical
-- HUBSPOT_DEAL_OWNER-tagged pod against their current STG_SALESFORCE__USER team), but caught
-- it producing false positives BEFORE shipping and killed it rather than ship it caveated.
-- HUBSPOT_DEAL_OWNER is not a clean per-person field -- confirmed live TWICE: "Cory Baach" and
-- "Evan Klein" (both real, current, correctly-tagged Strategic reps) each carry a large block
-- of deals tagged under a DIFFERENT team than their own (Evan Klens's case: 675,483 units
-- tagged "Brandon's Team" vs only 101,491 under his real "Strategic Team" in the current
-- month alone -- a 6.6x bulk-attribution artifact, not a real reassignment). Since this
-- exact false-positive pattern is what Kevin just caught once already, shipping a second,
-- similarly-fragile inference on top of it isn't worth the risk. If a reassignment view is
-- wanted, build it scoped like oneonone_prep.sql (one pod's own roster at a time, a narrower
-- and already-validated population) instead of a global HUBSPOT_DEAL_OWNER guess.
--
-- {{ LookbackMonths.value }} (default 6) only bounds which reps are considered "real
-- production reps worth checking" (anyone with unit production in that window) -- it does NOT
-- affect the departure determination itself, which is always based on CURRENT status.
--
-- Validated live 2026-07-29: Cory Baach/Doron David/Morgan Giles do NOT appear (correctly
-- cleared). Jason Rosen/Zach Branson/Jacob Fidler appear as departed (matches earlier
-- confirmed-departed findings elsewhere in this repo).

WITH production_reps AS (
    -- 'Unknown' is a HubSpot placeholder value, not a real person -- excluded, same principle
    -- as every other junk-value exclusion in this repo (don't let a placeholder masquerade as
    -- a departed rep).
    SELECT DISTINCT HUBSPOT_DEAL_OWNER AS rep
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND HUBSPOT_DEAL_OWNER IS NOT NULL AND HUBSPOT_DEAL_OWNER != 'Unknown'
),
user_dedup AS (
    SELECT FULL_NAME, TEAM_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
)
SELECT
    r.rep,
    u.TEAM_NAME             AS last_known_team,
    u.LAST_LOGIN_AT_UTC      AS last_login,
    IFF(u.FULL_NAME IS NULL, NULL, DATEDIFF(day, u.LAST_LOGIN_AT_UTC, CURRENT_DATE())) AS days_since_last_login
FROM production_reps r
LEFT JOIN user_dedup u ON u.FULL_NAME = r.rep
WHERE u.FULL_NAME IS NULL
   OR (NOT u.IS_ACTIVE AND (u.LAST_LOGIN_AT_UTC IS NULL OR u.LAST_LOGIN_AT_UTC < DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())))
ORDER BY last_login ASC NULLS FIRST;
