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
-- RECENCY FILTER -- added 2026-07-28, real bug Kevin caught: this had NO date bound at all,
-- so it was showing "Failed to Roll Out" deals from 7+ months ago as if they were current --
-- confirmed live, "Redstone Residential - Expansion" (the top row Kevin saw) was last
-- modified 2025-12-17, not remotely recent. A Watch List is for what's actionable NOW, not a
-- historical archive of every failure ever. Filtered on LAST_MODIFIED_DATE_UTC (the closest
-- proxy available to "when this was actually marked failed/delayed" -- there's no dedicated
-- "date marked Failed to Roll Out" field on this table; STG_SALESFORCE__IMPLEMENTATION_HISTORY
-- tracks field-level changes and could give an exact date if this proxy ever proves
-- insufficient, not built here since LAST_MODIFIED_DATE_UTC lines up with the real complaint).
-- Applied to BOTH stages, not just Failed to Roll Out -- Onboarding Delayed had the identical
-- staleness risk (nothing stops an old delayed record from sitting there indefinitely once its
-- anticipated date has passed).
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
  AND i.LAST_MODIFIED_DATE_UTC >= DATEADD(month, -{{ RecencyMonths.value }}, CURRENT_DATE())  -- default 2
  -- SEGMENT EXCLUSION -- added 2026-07-28, real bug Kevin caught: GTM Support Teams and
  -- DSMB 2 (and every other DSMB/Partner/SDR/leadership pod) were showing up on the Watch
  -- List with no exclusion at all -- this branch never had the segment_bucket IS NOT NULL
  -- filter that every other query in this repo has. Using the BROADER segment_bucket (not
  -- the narrower team_bucket above) -- House Accounts and Not Set should still be able to
  -- show up here, only DSMB/Partner/SDR/GTM Support/leadership pods are excluded.
  AND CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN e.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN e.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN e.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END IS NOT NULL
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

-- ==========================================================================================
-- SECOND SOURCE, added 2026-07-28 -- Kevin: "watch list should also include stuck deals -
-- particularly larger ones (mm/ent or strategic). not just failed rollouts." A deal can be a
-- real risk long before it ever reaches an Implementation record -- something that's been
-- sitting in Negotiation for 600+ days never fails or succeeds, it just rots, and nothing
-- above would ever catch it since STG_SALESFORCE__IMPLEMENTATION only exists post-close.
--
-- Reuses the exact "currently stuck" logic from insights_stage_velocity.sql Part B (segment's
-- own trailing-90-day baseline, not a fixed number of days -- Strategic/MM deals are SUPPOSED
-- to take longer, so the bar has to be relative to that segment, never absolute or borrowed
-- from a different segment). Scoped to MM/Ent and Strategic specifically per Kevin, plus the
-- same size floor as the rest of this watch list -- a small stuck SMB deal isn't watch-list
-- material, a $20K-unit stuck Strategic deal is.
--
-- REAL VALIDATED FINDINGS, not hypothetical: Coastal Ridge Real Estate Expansion (Brandon
-- Nicastro, MM/Ent) -- 20,000 units, 644 days in Negotiation against a 0.7-day segment
-- baseline. Apartment Management Consultants New Deal (Evan Klein, MM/Ent) -- 155,000 units,
-- 580 days. These are exactly the kind of large, silently-rotting deals a failed-rollout-only
-- watch list would never surface.
UNION ALL
SELECT
    s.OPPORTUNITY_ID                                         AS opportunity_id,
    s.OPPORTUNITY_NAME                                        AS implementation,
    'Stuck in Negotiation'                                    AS stage,
    s.days_in_negotiation || ' days in Negotiation (segment baseline: ' || s.segment_baseline_days || ' days)' AS reason,
    s.FLEX_UNIT_COUNT                                         AS units,
    COALESCE(s.rep_team, 'Not Set')                           AS team,
    s.team_bucket,
    NULL                                                       AS anticipated_go_live_date,
    s.OPPORTUNITY_NAME || ' -- Stuck in Negotiation (' || s.days_in_negotiation ||
        ' days vs. ' || s.segment_baseline_days || '-day segment baseline) -- ' ||
        s.FLEX_UNIT_COUNT || ' units'                          AS callout
FROM (
    SELECT
        sc.OPPORTUNITY_ID, sc.OPPORTUNITY_NAME, sc.FLEX_UNIT_COUNT,
        DATEDIFF(day, sc.NEGOTIATION_AT_UTC, CURRENT_DATE()) AS days_in_negotiation,
        ROUND(b.avg_days, 1) AS segment_baseline_days,
        sc.rep_team,
        CASE
            WHEN sc.rep_team = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN sc.rep_team = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN sc.rep_team = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN sc.rep_team IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM (
        SELECT
            o.OPPORTUNITY_ID, o.OPPORTUNITY_NAME, o.FLEX_UNIT_COUNT, o.NEGOTIATION_AT_UTC, o.DEAL_REVIEW_AT_UTC, o.IS_CLOSED,
            e.TEAM_NAME AS rep_team,
            CASE
                WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
                WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
                WHEN o.STATIC_TEAM_NAME IS NULL THEN 'Not Set'
                ELSE NULL
            END AS segment_bucket
        FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
        LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
        WHERE o.NEGOTIATION_AT_UTC IS NOT NULL AND o.NEGOTIATION_AT_UTC <= CURRENT_DATE()
    ) sc
    JOIN (
        SELECT
            CASE
                WHEN o2.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                WHEN o2.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
                WHEN o2.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                WHEN o2.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
                WHEN o2.STATIC_TEAM_NAME IS NULL THEN 'Not Set'
                ELSE NULL
            END AS segment_bucket,
            AVG(DATEDIFF(day, o2.NEGOTIATION_AT_UTC, o2.DEAL_REVIEW_AT_UTC)) AS avg_days
        FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o2
        WHERE o2.DEAL_REVIEW_AT_UTC IS NOT NULL
          AND o2.NEGOTIATION_AT_UTC IS NOT NULL
          AND o2.NEGOTIATION_AT_UTC >= DATEADD(day, -90, CURRENT_DATE())
        GROUP BY 1
    ) b ON sc.segment_bucket = b.segment_bucket
    WHERE sc.DEAL_REVIEW_AT_UTC IS NULL AND NOT sc.IS_CLOSED
      AND sc.segment_bucket IN ('MM/Ent', 'Strategic')
      AND sc.FLEX_UNIT_COUNT >= {{ SizeFloor.value }}
      AND DATEDIFF(day, sc.NEGOTIATION_AT_UTC, CURRENT_DATE()) > 1.5 * NULLIF(b.avg_days, 0)
) s
{{#Team.value}} WHERE s.team_bucket = '{{Team.value}}' {{/Team.value}}

ORDER BY units DESC;
