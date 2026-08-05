-- Open Opportunities Drill-Down -- the per-opportunity list underneath Open Opportunities by
-- Segment/MSP (Opportunity/Account/Owner/Stage/Units/Days, searchable). Kevin found this
-- table showing a deal owned by MJ Oommen (confirmed departed) whose Salesforce record says
-- "no longer available" when clicked -- and asked "how are you seeing this deal if the
-- opportunity doesn't exist?" No query in this repo powered this exact list (Opportunity/
-- Account/Owner/Stage/Units/Days with a search box) -- built independently in Superblocks,
-- same recurring pattern as everywhere else in this repo. This is the validated version.
--
-- ROOT CAUSE OF THE "RECORD NO LONGER AVAILABLE" BUG, confirmed live 2026-07-29 --
-- FCT_CRM_OPPORTUNITY blends TWO SOURCE SYSTEMS with incompatible ID spaces:
--   - Salesforce-native: OPPORTUNITY_ID is a real 18-char Salesforce ID ("006..."). 17,829 of
--     53,430 total opportunities (33%), but only 2,055 of 10,724 OPEN ones (19%).
--   - HubSpot-origin: OPPORTUNITY_ID is a plain numeric string (e.g. "37906234041") -- NOT a
--     Salesforce ID at all. 35,601 of 53,430 total (67%), 8,669 of 10,724 open ones (81%).
-- The Greystar Management / MJ Oommen deal Kevin found is HubSpot-origin -- there never was a
-- Salesforce Opportunity record to click through to, which is exactly why it 404s. This isn't
-- a broken link, it's a genuinely nonexistent Salesforce record.
--
-- THIS EXPLAINS MORE THAN THE LINK -- checked live: HubSpot-origin open "opportunities" have a
-- median age of 431 days and 99.9% (8,659 of 8,669) have NEVER had a single real Task/Meeting
-- logged against them in Salesforce. Salesforce-native open opportunities: median age 36 days,
-- only 25% zero-activity. HubSpot-origin records are almost entirely pre-Salesforce-migration
-- leftovers that were never cleaned up when Flex switched CRMs -- not "bad hygiene" on current
-- deals, a wholesale legacy-system carryover. This is WHY open_opportunities_by_segment.sql's
-- real-activity staleness filter cut the "fresh" pipeline number so hard (14.8M -> 2.6M) --
-- it was mostly filtering out exactly this population. Same filter reused here for the same
-- reason, and it's why nearly every row in this drill-down IS Salesforce-native once filtered.
--
-- NOTES / NEXT STEP / DATA QUALITY SCORE -- Kevin: "is it possible to pull in opp notes? most
-- recent notes and maybe even next step date?" These fields don't exist on FCT_CRM_OPPORTUNITY
-- itself -- found them on the raw Salesforce sync. TWO raw sync tables exist and they are NOT
-- equally reliable -- checked live: EXTERNAL_DATA.SALESFORCE.OPPORTUNITY (the "direct" sync)
-- only matches 19% (398/2055) of Salesforce-native open opportunities -- it's stale/lagged,
-- missing most recently-created deals. EXTERNAL_DATA.POLYTOMIC.SALESFORCE_OPPORTUNITY matches
-- 100% (2055/2055) -- use THIS one, not the other, for any opportunity-level Salesforce field.
-- Fields used: OPPORTUNITY_NOTES__C, NEXTSTEP, NEXT_STEP_DATE__C, DATA_QUALITY_SCORE__C.
-- These will always be NULL for HubSpot-origin rows (no Salesforce record exists to pull from,
-- not a join bug) -- surfaced via is_legacy_no_sf_record below so the UI can show "no
-- Salesforce record" instead of a blank that looks like a data gap.
--
-- SALESFORCE DEEP LINK -- domain confirmed by Kevin 2026-07-29: getflex.lightning.force.com.
-- `salesforce_url` is built directly below using the standard Lightning record-page pattern.
-- Every row here already has a real 006-prefix ID (legacy HubSpot-origin rows are excluded
-- entirely, see below) so the URL is always valid -- no per-row gating needed anymore.
--
-- LEGACY RECORDS EXCLUDED BY DEFAULT -- checked live: the account-level staleness filter alone
-- isn't enough to catch every legacy record -- Greystar/MJ Oommen still passed it, because
-- SOME activity exists on that ACCOUNT (from an unrelated, real opportunity) even though this
-- SPECIFIC HubSpot-origin opportunity record has no Salesforce anchor and can never be updated
-- going forward. `is_legacy_no_sf_record` is filtered out entirely below rather than left to
-- the staleness heuristic -- there were only 7 of these in a recent test run, small enough that
-- hard-excluding is safe, and it directly fixes the exact bug Kevin found. If auditing the
-- legacy population itself becomes useful later, remove the filter rather than adding a toggle
-- nobody's asked for yet.
--
-- OWNER STATUS -- shown, not used to exclude the row. A departed rep's deal is still real open
-- pipeline that needs a new owner -- this list's job is to show what's actually open, same
-- principle as insights_stage_velocity.sql Part B (departed owner shown as a fact, not hidden).
-- Uses DIM_EMPLOYEE_HISTORY.TEAM_NAME/IS_ACTIVE directly (not the Salesforce-sourced-only dedup
-- pattern used for rep-listing queries elsewhere) since OWNER_SK on open deals is mostly
-- HubSpot-sourced (see open_opportunities_by_segment.sql's header) -- restricting to
-- SOURCE_SYSTEM='salesforce' here would blank out most owners.
--
-- Deal type tag (New Logo / Expansion / etc.) is OPPORTUNITY_TYPE, already on the base table.

WITH user_dedup AS (
    SELECT EMAIL, IS_ACTIVE
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
last_activity AS (
    SELECT CRM_ACCOUNT_SK, MAX(activity_date) AS last_activity_date
    FROM (
        SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
        UNION ALL
        SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
    )
    GROUP BY 1
)
SELECT
    o.OPPORTUNITY_NAME                                  AS opportunity,
    a.ACCOUNT_NAME                                       AS account,
    e.FULL_NAME                                          AS owner,
    u.IS_ACTIVE                                           AS owner_is_active,
    o.CURRENT_STAGE                                       AS stage,
    o.OPPORTUNITY_TYPE                                    AS deal_type,
    o.FLEX_UNIT_COUNT                                     AS units,
    DATEDIFF(day, o.CREATED_AT_UTC, CURRENT_DATE())       AS days_open,
    -- Added 2026-08-05, Kevin: "is days right now the total days the opp has been open?" --
    -- yes, days_open is since CREATED_AT_UTC, total age, not activity. This is the real
    -- last-human-touch signal (same MAX(completed Task/Meeting) definition already used in
    -- this file's own recency WHERE filter, and the same fix README documents for
    -- UPDATED_AT_UTC not being trustworthy) -- falls back to CREATED_AT_UTC when an
    -- opportunity has never had a single logged activity, so a never-touched deal reads as
    -- "as old as it is," not NULL.
    -- Validated live against the exact deals Kevin was looking at: RPM Living Move In is
    -- days_open=285 but days_since_last_touch=1 -- old but actively worked, not stalled. MAA
    -- New Logo is the more useful catch: days_open=51 but days_since_last_touch=57 -- a
    -- last-touch OLDER than the deal's own age. Not a bug: `la` joins on CRM_ACCOUNT_SK (the
    -- same grain the recency WHERE filter already uses), so it can reflect real activity that
    -- happened on the ACCOUNT before this specific opportunity record was created -- a deal
    -- can look "only 51 days old" by creation date while the account itself has been quiet
    -- much longer. That's a real, useful signal here (this MAA deal reads as routine by age
    -- alone but is actually stalling), not something to clamp to days_open.
    DATEDIFF(day, COALESCE(la.last_activity_date, o.CREATED_AT_UTC), CURRENT_DATE()) AS days_since_last_touch,
    sfo.OPPORTUNITY_NOTES__C                              AS opportunity_notes,
    sfo.NEXTSTEP                                          AS next_step,
    sfo.NEXT_STEP_DATE__C                                 AS next_step_date,
    sfo.DATA_QUALITY_SCORE__C                              AS data_quality_score,
    o.OPPORTUNITY_ID                                      AS opportunity_id,
    'https://getflex.lightning.force.com/lightning/r/Opportunity/' || o.OPPORTUNITY_ID || '/view' AS salesforce_url,
    CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN e.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN e.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN e.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END                                                    AS segment_bucket
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
LEFT JOIN user_dedup u ON u.EMAIL = e.EMAIL
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
LEFT JOIN EXTERNAL_DATA.POLYTOMIC.SALESFORCE_OPPORTUNITY sfo ON o.OPPORTUNITY_ID = sfo.ID
LEFT JOIN last_activity la ON o.CRM_ACCOUNT_SK = la.CRM_ACCOUNT_SK
WHERE NOT o.IS_CLOSED
  AND o.OPPORTUNITY_ID LIKE '006%'
  AND COALESCE(la.last_activity_date, o.CREATED_AT_UTC) >= DATEADD(month, -{{ RecencyMonths.value }}, CURRENT_DATE())
  AND CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN e.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN e.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN e.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END IS NOT NULL
  {{#Segment.value}}  AND CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN e.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN e.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN e.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END = '{{Segment.value}}' {{/Segment.value}}
  {{#DealType.value}} AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
  {{#Search.value}}   AND (o.OPPORTUNITY_NAME ILIKE '%{{Search.value}}%' OR a.ACCOUNT_NAME ILIKE '%{{Search.value}}%') {{/Search.value}}
ORDER BY o.FLEX_UNIT_COUNT DESC NULLS LAST;
