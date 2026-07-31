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
--
-- TREND_FLAG + PCT_CHANGE ADDED 2026-07-31 -- Sham wants an icon/%-change signal on this table,
-- but per Kevin's own flag, this table is already dense (This + Last = 2 columns per MSP,
-- times up to 9 MSPs). Computed here rather than left for Superblocks to derive so the UI
-- binds to a real value instead of guessing a formula in the presentation layer.
--
-- `trend_flag` is the thing to bind an icon to ('up'/'down'/'new'/'dropped'/'flat') -- NOT
-- `pct_change` directly, because a raw % is meaningless or wildly misleading at the small-base
-- end of this table (e.g. Ariel Kurek's RealPage: 597 -> 0 this month is a real, complete drop-
-- off, but "-100%" reads the same as any other -100% regardless of whether the base was 597 or
-- 5). 'new' (last=0, this>0) and 'dropped' (this=0, last>0) get their own flag specifically so
-- the UI can show a badge ("New" / "Dropped") instead of an undefined-or-nonsensical
-- percentage. `pct_change` is only meaningful (and only non-NULL) for the plain 'up'/'down'
-- case where both periods have a real base to compare against.
--
-- INTENDED UI TREATMENT (Superblocks side, not enforced here): collapse the existing "This" +
-- "Last" columns into ONE column -- bold `units_this`, small icon keyed to `trend_flag`
-- (filled triangle up/down in status color, not categorical color; a neutral "New"/"Dropped"
-- badge for those two cases), muted `pct_change` next to the icon only when it's non-NULL.
-- `units_last` stays available for a tooltip on hover, not as its own visible column -- this
-- nets FEWER visible columns than today even after adding the new signal, which is the actual
-- fix for "too many cells," not an addition on top of the current layout.

WITH base AS (
    SELECT * FROM (
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
    )
)
SELECT
    rep,
    msp,
    segment_bucket,
    team_bucket,
    units_this,
    units_last,
    CASE
        WHEN units_last = 0 AND units_this > 0 THEN 'new'
        WHEN units_this = 0 AND units_last > 0 THEN 'dropped'
        WHEN units_this > units_last THEN 'up'
        WHEN units_this < units_last THEN 'down'
        ELSE 'flat'
    END AS trend_flag,
    IFF(units_last > 0 AND units_this > 0, DIV0(units_this - units_last, units_last), NULL) AS pct_change
FROM base
ORDER BY rep, units_this DESC;
