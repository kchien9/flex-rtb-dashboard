-- Rep x MSP breakdown -- the drill-down when clicking a Segment on the Segment x MSP x Month
-- matrix (rolled_out_units_cube.sql with Dimension=PMS). Per Kevin: "when i click the segment
-- i want to see the rep by msp breakdown" -- a flat rep total (rep_leaderboard.sql) doesn't
-- show which MSPs make up each rep's number, so this is a separate, more granular query
-- rather than changing rep_leaderboard.sql's grain (that query also feeds the app's Rep
-- filter dropdown and the flat team/segment drill -- changing its GROUP BY to include PMS
-- would multiply its rows and break both of those other uses).
--
-- Same DSMB exclusion, segment_bucket/team_bucket exclusion, and departure grace period as
-- rep_leaderboard.sql -- kept consistent so a rep who's excluded/included there is excluded/
-- included here too. Long format (rep, msp, units) -- pivot into Rep rows x MSP columns in
-- Superblocks, same technique as the Segment x MSP x Month matrix.
--
-- REBUILT 2026-07-30 -- same fix as rep_leaderboard.sql, same day, same root cause: segment_
-- bucket/team_bucket now resolve once per rep from their CURRENT STG_SALESFORCE__USER.
-- TEAM_NAME instead of each row's HUBSPOT_STATIC_TEAM_NAME_DEAL -- see that file's header for
-- the full writeup (Rory Averett is a manager now, but his old deals are still tagged under a
-- Strategic-mapped pod). Kept consistent with rep_leaderboard.sql per this file's own stated
-- goal above.
--
-- Validated live 2026-07-28 (pre-rebuild, still holds): House Accounts, Morgan Giles --
-- Entrata 142, RealPage 2,795, Yardi 3,049 -- sums to 5,986, matching her total in
-- rep_leaderboard.sql exactly (cross-checked, ties out).
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
user_dedup AS (
    SELECT FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
current_rep AS (
    SELECT
        FULL_NAME,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
            WHEN TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            WHEN TEAM_NAME IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM user_dedup
)
SELECT
    s.HUBSPOT_DEAL_OWNER                                                              AS rep,
    COALESCE(s.PMS, 'Not Set')                                                        AS msp,
    cr.segment_bucket,
    cr.team_bucket,
    SUM(IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
            AND s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))                       AS units_this,
    SUM(IFF(s.BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
            AND s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))                       AS units_last
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
JOIN current_rep cr ON cr.FULL_NAME = s.HUBSPOT_DEAL_OWNER
WHERE s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND cr.segment_bucket IS NOT NULL
  AND (cr.IS_ACTIVE OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
  {{#Team.value}}     AND cr.team_bucket = '{{Team.value}}'       {{/Team.value}}
  {{#Segment.value}}  AND cr.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
GROUP BY 1, 2, 3, 4
HAVING units_this > 0 OR units_last > 0
ORDER BY rep, units_this DESC;
