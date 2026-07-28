-- Watch List, Section 1: Large Deals at Risk
-- Sham's grain, not a rep's -- deal-level, size-weighted. A small stalled deal isn't worth
-- his attention (that's the AE manager's problem); a big one that failed to roll out or is
-- overdue is exactly the kind of thing he should see without having to go looking for it.
--
-- ==========================================================================================
-- REBUILT 2026-07-27 ON THE RIGHT SOURCE -- everything before this was inference (checking
-- PROPERTY_BP_MONTH_STATS for the ABSENCE of a positive rollout signal) and went through six
-- rounds of real bugs: wrong join key type, missing historical check, BP-vs-calendar date
-- mismatch, a property dedup/linking business process that orphans placeholder PROPERTY_IDs,
-- Uplevel deals not tracked the same way as new rollouts, and ambiguous duplicate deal names.
--
-- Kevin caught the final case directly in Salesforce: "Preferred Apartment Communities, Inc.
-- Expansion" (opportunity 006Pe00000y5On7IAE) really had failed -- Stage "Failed to Roll
-- Out", reason "PMC Changed Their Mind" -- and pointed at the actual source of truth:
-- Salesforce has a dedicated Implementation object for exactly this. It's synced into
-- Snowflake as FLEX.STG_SALESFORCE.STG_SALESFORCE__IMPLEMENTATION, with IMPLEMENTATION_STAGE,
-- ROLL_OUT_FAILURE_REASON, DELAYED_REASON, and a direct OPPORTUNITY_ID join -- no inference
-- needed at all. This replaces every heuristic above.
--
-- IMPLEMENTATION_STAGE values (confirmed live, IS_DELETED = FALSE): Ready to Market (9,981
-- records, the completed/live state), Ready to Onboard (547), Failed to Roll Out (498,
-- 181,528 units -- the definitive failure state), Onboarding Delayed (101), Onboarding In
-- Progress (66), Partial Deal Active (29).
--
-- "Failed to Roll Out" is terminal -- flag regardless of date. "Onboarding Delayed" is only
-- a real risk once its own anticipated go-live date has actually passed -- a few delayed
-- records had anticipated dates still in the current/future BP period, which isn't overdue,
-- it's just in progress. Filtered accordingly below.
-- ==========================================================================================
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.
--
-- TEAM BUCKET (added 2026-07-28) -- same mapping as performance_cube.sql/
-- rolled_out_units_cube.sql, scoped to Sham's 4 units-side direct-report managers. Same
-- caveat as the Meetings query in performance_cube.sql: built off DIM_EMPLOYEE_HISTORY.
-- TEAM_NAME (rep-grain), which has real data quality gaps -- flag, don't silently trust.
--
-- SALESFORCE LINK -- opportunity_id is already the real Salesforce Opportunity ID (the "006"
-- prefix is Salesforce's standard Opportunity ID format) -- link directly to
-- https://<domain>.lightning.force.com/lightning/r/Opportunity/{opportunity_id}/view in
-- Superblocks, don't add anything else to this query for that.

SELECT
    o.OPPORTUNITY_ID                                        AS opportunity_id,
    i.IMPLEMENTATION_NAME                                    AS implementation,
    i.IMPLEMENTATION_STAGE                                   AS stage,
    COALESCE(i.ROLL_OUT_FAILURE_REASON, i.DELAYED_REASON)    AS reason,
    i.FLEX_UNITS                                             AS units,
    COALESCE(e.TEAM_NAME, 'Not Set')                         AS team,
    CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
        ELSE NULL
    END                                                       AS team_bucket,
    i.ANTICIPATED_GO_LIVE_DATE                                AS anticipated_go_live_date,
    i.IMPLEMENTATION_NAME || ' -- ' || i.IMPLEMENTATION_STAGE ||
        IFF(COALESCE(i.ROLL_OUT_FAILURE_REASON, i.DELAYED_REASON) IS NOT NULL,
            ' (' || COALESCE(i.ROLL_OUT_FAILURE_REASON, i.DELAYED_REASON) || ')', '') ||
        ' -- ' || i.FLEX_UNITS || ' units'                    AS callout
FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__IMPLEMENTATION i
LEFT JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON i.OPPORTUNITY_ID = o.OPPORTUNITY_ID
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
WHERE i.IS_DELETED = FALSE
  AND i.FLEX_UNITS >= {{ SizeFloor.value }}  -- default 100
  AND (
      i.IMPLEMENTATION_STAGE = 'Failed to Roll Out'
      OR (i.IMPLEMENTATION_STAGE = 'Onboarding Delayed' AND i.ANTICIPATED_GO_LIVE_DATE < CURRENT_DATE())
  )
  {{#Team.value}} AND CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
        ELSE NULL
    END = '{{Team.value}}' {{/Team.value}}
ORDER BY i.FLEX_UNITS DESC;
