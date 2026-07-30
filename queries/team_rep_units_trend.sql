-- Team Rep Units Trend -- Kevin: "in each manager pod can we add a button that trends
-- everyones monthly rolled out units across the team?" A multi-rep line chart (one line per
-- rep) for a single manager's pod, so Rory/Sebastian/Brandon/Dana (or Sham looking at any of
-- them) can see who's accelerating or decelerating relative to teammates at a glance, without
-- clicking into each rep's individual rep_detail.sql page one at a time.
--
-- Requires {{ Team.value }} to be set (one of Brandon's/Rory's/Sebastian's/Dana's Team) --
-- this is scoped to ONE pod at a time, meant to sit behind a "trend this team" button on that
-- pod's card, not run unfiltered across everyone.
--
-- REBUILT 2026-07-30 -- TEAM MEMBERSHIP MUST COME FROM THE PERSON, NOT THE DEAL. Kevin caught
-- Rory Averett appearing under Dana's Team: "rory is now a manager so shouldnt be here too...
-- how do we fix this across the entire dashboard. bc we keep having issues here w this."
-- Checked live: Rory Averett's CURRENT record says TEAM_NAME='SMB Manager' (he's a manager,
-- not an IC) -- but his old deals are still tagged HUBSPOT_STATIC_TEAM_NAME_DEAL="Cory's Team"
-- (76,589 rows, $3.85M in historical units), which this file's first version used to decide
-- team_bucket. That's the exact same bulk-attribution artifact already found and worked around
-- for Cory Baach and Evan Klein elsewhere in this repo (see possible_departures.sql's header)
-- -- a deal's OWN team tag reflects who owned it historically, not who the person is today.
-- FIX, same principle everywhere in this repo from now on: team_bucket is resolved ONCE per
-- PERSON from their CURRENT STG_SALESFORCE__USER.TEAM_NAME (with the PARENT_TEAM='Mid Market +'
-- guard for the Strategic pod, same as activity_vs_outcome_by_rep.sql etc.) -- NEVER from
-- HUBSPOT_STATIC_TEAM_NAME_DEAL on their individual rolled-out-unit rows. A manager like Rory
-- now resolves to team_bucket = NULL (SMB Manager isn't one of the 4 IC pods) and correctly
-- drops off every team's rep chart -- not because his old units are hidden, but because he's
-- not an IC to plot as one anymore.
--
-- Same departure-grace-period exclusion as before ({{ GraceMonths.value }}, default 2) --
-- confirmed live Perry Schwinger (IS_ACTIVE=FALSE, LAST_LOGIN_AT_UTC=NULL, well past any grace
-- window) is correctly absent from this query's own output already -- if he's still showing on
-- screen, that's Superblocks not running this file, not a gap in the logic below.
--
-- Rolled-out units basis (HUBSPOT_DEAL_OWNER, PROPERTY_BP_MONTH_STATS) unchanged -- still the
-- source of the unit VALUES, just no longer used to decide team MEMBERSHIP.

WITH user_dedup AS (
    SELECT FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
current_team AS (
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
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
SELECT
    DATE_TRUNC('month', s.BP_MONTH)  AS bp_month,
    s.HUBSPOT_DEAL_OWNER             AS rep,
    SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS units
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
JOIN current_team ct ON ct.FULL_NAME = s.HUBSPOT_DEAL_OWNER
WHERE ct.team_bucket = '{{ Team.value }}'
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND (ct.IS_ACTIVE OR ct.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
  AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
GROUP BY 1, 2
ORDER BY rep, bp_month;
