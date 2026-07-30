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
-- Same dedup + departure-grace-period + DSMB exclusion as rep_leaderboard.sql (deduped
-- STG_SALESFORCE__USER, {{ GraceMonths.value }} default 2) -- a departed rep's trailing months
-- of real production still show (so the line doesn't just vanish mid-chart), but someone gone
-- well past the grace window drops off entirely, same rule as everywhere else in this repo.
--
-- Rolled-out units basis (HUBSPOT_DEAL_OWNER, PROPERTY_BP_MONTH_STATS), same as
-- rep_leaderboard.sql and rep_detail.sql Part A -- one consistent "rep's units" definition
-- across every rep-level view in this repo.

WITH deal_owner_status AS (
    SELECT FULL_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
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
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
)
SELECT
    DATE_TRUNC('month', s.BP_MONTH)  AS bp_month,
    s.HUBSPOT_DEAL_OWNER             AS rep,
    SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS units
FROM base s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
LEFT JOIN deal_owner_status u ON u.FULL_NAME = s.HUBSPOT_DEAL_OWNER
WHERE s.team_bucket = '{{ Team.value }}'
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND s.HUBSPOT_DEAL_OWNER IS NOT NULL
  AND (u.FULL_NAME IS NULL OR u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
  AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
GROUP BY 1, 2
ORDER BY rep, bp_month;
