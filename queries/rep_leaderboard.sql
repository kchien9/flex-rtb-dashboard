-- Rep Leaderboard -- ranked rep view, on-demand not default. Per Kevin: "hes more mgrs not
-- reps but he should have a view into reps too if he needs to" -- this reverses my earlier
-- caution about conflicting with the "Sham manages managers" principle (see oneonone_prep.sql
-- and insights_stage_velocity.sql headers for that principle elsewhere in this repo). Resolved:
-- it's fine for Sham to HAVE rep-level access, it's just not what should be pushed to him by
-- default -- wire this as a drill-through / separate tab a click away from the team-level
-- views, not a headline panel on the main dashboard.
--
-- Same base and same DSMB exclusion as rolled_out_units_cube.sql (PMC current live unit total
-- <=750, not segment/team). Ranked by new_integrated_units (this period vs last), with team
-- shown so Sham can see who's under which manager without a separate lookup.
--
-- BUG CAUGHT WHILE VALIDATING (2026-07-27): first draft put the last-period conditional SUM
-- inside a WHERE clause that already restricted to only the current BP month -- units_last
-- came back 0 for every single rep, not because it's really zero but because the outer WHERE
-- had already thrown away every row that could have matched. Fixed by widening the WHERE to
-- both months and doing the period split entirely inside the two conditional SUMs.
--
-- SEGMENT/TEAM BUCKET EXCLUSION (added 2026-07-28) -- this query is also the natural source
-- for the app's Rep filter dropdown (per Kevin: "DSMB reps should not be in the rep
-- dropdown"). Excluded via segment_bucket IS NOT NULL -- the BROADER bucket (keeps House
-- Accounts/Not Set reps, only drops DSMB/Partner Success/SDR/leadership pods), not the
-- narrower team_bucket -- a rep leaderboard should show every legitimate production rep, not
-- just the 4 direct-report pods. team_bucket is still exposed as its own column for when the
-- Team filter (which DOES use the narrower bucket) is applied on this page.
--
-- DEPARTURE GRACE PERIOD (added 2026-07-28) -- Kevin: "Ariel juuust left... they shouldnt
-- disappear immediately... might want to keep for one or two months post departure." Uses
-- FLEX.STG_SALESFORCE.STG_SALESFORCE__USER.LAST_LOGIN_AT_UTC as the "roughly when they
-- stopped working here" signal -- IS_ACTIVE alone doesn't carry a date, and this repo already
-- confirmed IS_ACTIVE flips to FALSE immediately on departure (correct for Ariel Kurek,
-- verified with Kevin -- she really did just leave), so a hard IS_ACTIVE filter would drop
-- someone the day they leave with zero grace period. {{ GraceMonths.value }} (default 2)
-- keeps anyone whose last real login is within that window even if IS_ACTIVE is now FALSE.
-- Real validated behavior: Ariel Kurek (last login 4 days ago) and Redding Tews (11 days ago)
-- -> kept; Jacob Fidler (~7 months ago) and Zach Branson (~10 months ago) -> dropped.
--
-- DUPLICATE USER RECORDS -- confirmed live: Morgan Giles and Brad Robins each have TWO
-- STG_SALESFORCE__USER rows (one real/active, one stale/deactivated with a mangled username)
-- -- a naive join on FULL_NAME would non-deterministically match either one. Deduped via
-- QUALIFY, preferring the active row (or the more recently logged-in row if both are
-- inactive) before joining.
--
-- SEGMENT/MSP FILTERS (added 2026-07-28) -- feeds the "drill into segment to see rep" ask on
-- the Segment x MSP x Month matrix view (rolled_out_units_cube.sql with Dimension=PMS). PMS
-- is already available via s.* from PROPERTY_BP_MONTH_STATS, no join needed.

WITH pmc_size AS (
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
),
user_dedup AS (
    SELECT FULL_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
)
SELECT
    s.HUBSPOT_DEAL_OWNER                                                              AS rep,
    s.HUBSPOT_STATIC_TEAM_NAME_DEAL                                                   AS team,
    s.segment_bucket,
    s.team_bucket,
    SUM(IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
            AND s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))                       AS units_this,
    SUM(IFF(s.BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
            AND s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))                       AS units_last,
    SUM(IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
            AND (s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER), s.PROPERTY_UNIT_COUNT, 0)) AS recaptured_units_this
FROM base s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
LEFT JOIN user_dedup u ON u.FULL_NAME = s.HUBSPOT_DEAL_OWNER
WHERE s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND s.HUBSPOT_DEAL_OWNER IS NOT NULL
  AND s.segment_bucket IS NOT NULL
  -- departure grace period: keep if no user record match (don't punish a join miss), OR
  -- currently active, OR inactive but logged in within the grace window
  AND (u.FULL_NAME IS NULL OR u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
  {{#Team.value}}     AND s.team_bucket = '{{Team.value}}'       {{/Team.value}}
  {{#Segment.value}}  AND s.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
  {{#Msp.value}}       AND s.PMS = '{{Msp.value}}'                {{/Msp.value}}
GROUP BY 1, 2, 3, 4
HAVING units_this > 0 OR units_last > 0
ORDER BY units_this DESC;
