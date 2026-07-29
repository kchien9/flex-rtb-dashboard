-- Open Opportunities, by Segment -- feeds the Pipeline tab per Kevin: "can we segment the
-- open opportunities? to see how many open opportunities each segment has? opps that havent
-- been touched in months can be excluded." Folded into Pipeline (not its own Opportunities
-- tab) per Kevin's own call -- this is a forward-looking pipeline-composition question, same
-- theme as the rest of that tab.
--
-- STALENESS FILTER -- REBUILT 2026-07-29, UPDATED_AT_UTC WAS NOT A REAL SIGNAL. Kevin: "i see
-- most of these have been opened for a very long time... some have been opened for 600+
-- days... i imagine this is just bad salesforce hygiene." Checked live: Trammell Crow (541
-- days open), King County Housing Authority (821 days), Capital Realty Group (628 days) --
-- all three have ZERO real tasks or meetings EVER logged against their account, yet
-- UPDATED_AT_UTC read as "3 weeks ago" on every one of them -- proof UPDATED_AT_UTC gets
-- touched by an automated field sync, not a human working the deal, so the old filter was
-- letting genuinely dead opportunities straight through. Real distribution checked live:
-- 9,182 of 10,720 open opps (12.6M of 15.2M units) have never had a single real task/meeting
-- logged at all -- but that alone isn't staleness either, a brand-new lead with zero activity
-- yet is normal, not a hygiene problem. The real signal is AGE combined with activity:
-- last_real_touch = COALESCE(MAX(real task/meeting date on the account), CREATED_AT_UTC) --
-- ages out both "went quiet after some activity" AND "created long ago, never worked" while
-- correctly treating a opportunity created days ago as fresh even with zero activity yet.
-- {{ RecencyMonths.value }} (default 3) controls the cutoff, same as before.
--
-- MAGNITUDE WARNING -- this is a much stricter filter than the old one and moves the headline
-- number a lot: only 1,636 of 10,720 open opps (2.6M of 15.2M units) pass a 3-month real-
-- activity bar. The old (broken) filter passed 10,384 opps / 14.8M units through as "fresh."
-- This is real -- most of Salesforce's open pipeline genuinely hasn't been touched by a human
-- in 3+ months -- not a bug in this query. If 2.6M feels too aggressive as the headline
-- "active pipeline" number, raise RecencyMonths' default rather than reverting to
-- UPDATED_AT_UTC, which is proven not to reflect real engagement at all.
--
-- TEAM ATTRIBUTION -- REBUILT 2026-07-29, STATIC_TEAM_NAME IS A BATCH-LAGGED FIELD ON OPEN
-- DEALS. Kevin: "im not sure the rolled out units by segment is right" led into checking why
-- segmenting OPEN pipeline by STATIC_TEAM_NAME put almost everything into "Not Set." Confirmed
-- live: STATIC_TEAM_NAME's attribution rate tracks deal AGE almost perfectly, not deal stage --
-- <30 days old: 0.1% attributed, 30-90 days: 0%, 90-365 days: 61%, >365 days: 98.7% -- and
-- "Not Set" deals progress through Qualification->Negotiation at the same rate as attributed
-- ones (ruling out "gets assigned once qualified" as the mechanism). It's a batch/ETL
-- snapshot field that hasn't caught up on anything created in roughly the last year -- which
-- is most of what "open pipeline" actually is. FIX: attribute via the deal's live OWNER_SK ->
-- DIM_EMPLOYEE_HISTORY.TEAM_NAME instead (same fix pipeline_forecast.sql already uses for the
-- same reason). Confirmed live this resolves cleanly -- OWNER_SK on open deals mostly matches
-- HubSpot-sourced employee records (80%), not Salesforce-sourced (20%, the opposite of the
-- activity-table pattern used elsewhere in this repo) -- so this join deliberately does NOT
-- restrict to SOURCE_SYSTEM='salesforce' the way the rep-listing fixes elsewhere do; it only
-- needs IS_CURRENT=TRUE and matches on OWNER_SK's exact EMPLOYEE_SK value directly (no EMAIL/
-- FULL_NAME fan-out risk since that's a precise 1:1 key match, not a name-based join). Real
-- distribution after the fix: MM/Ent 1,059 opps/$4.85M, Strategic 591/$3.75M, SMB 6,250/$2.99M,
-- only 17 opps genuinely unowned ("Not Set").
--
-- Excludes segment_bucket = NULL (DSMB/Partner/SDR/leadership pods -- 2,794 opps/$3.6M,
-- real volume that shouldn't get silently folded into a real segment's count, same principle
-- as everywhere else in this repo, just now measured via the live owner instead of the stale
-- deal-time field).
--
-- LEGACY HUBSPOT-ORIGIN RECORDS EXCLUDED (added 2026-07-29) -- see
-- open_opportunities_drilldown.sql's header for the full writeup: FCT_CRM_OPPORTUNITY blends
-- Salesforce-native opportunities (real 18-char "006..." IDs) with HubSpot-origin ones (plain
-- numeric IDs that were never a Salesforce record at all -- confirmed live this is the exact
-- cause of a "record no longer available" bug Kevin hit). Kevin, once this was explained:
-- "yea old open hubspot opportunities lets exclude. we migrated to sf over a year ago and
-- these i think are basically dead opportunities." The staleness filter above catches MOST of
-- these already (median age 431 days, 99.9% zero real activity), but not all -- some pass
-- because their ACCOUNT has unrelated recent activity from a different, real opportunity. The
-- explicit `OPPORTUNITY_ID LIKE '006%'` filter below closes that gap directly rather than
-- relying on the staleness heuristic alone.
--
-- DEAL TYPE BREAKDOWN (added 2026-07-29) -- Kevin: "can open opportunities show stacked
-- breakdown for new logo vs expansion type opportunity." `deal_type` is now a group-by column
-- so Superblocks can stack New Logo vs Expansion (vs whatever else) within each segment bar --
-- the existing {{DealType.value}} filter still works for narrowing to one type if needed.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.

WITH last_activity AS (
    SELECT CRM_ACCOUNT_SK, MAX(activity_date) AS last_activity_date
    FROM (
        SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
        UNION ALL
        SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
    )
    GROUP BY 1
)
SELECT
    CASE
        WHEN d.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN d.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN d.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN d.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN d.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END                                AS segment_bucket,
    o.OPPORTUNITY_TYPE                 AS deal_type,
    COUNT(*)                           AS open_opportunities,
    SUM(o.FLEX_UNIT_COUNT)             AS open_pipeline_units
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY d ON o.OWNER_SK = d.EMPLOYEE_SK AND d.IS_CURRENT = TRUE
LEFT JOIN last_activity la ON o.CRM_ACCOUNT_SK = la.CRM_ACCOUNT_SK
WHERE NOT o.IS_CLOSED
  AND o.OPPORTUNITY_ID LIKE '006%'
  AND COALESCE(la.last_activity_date, o.CREATED_AT_UTC) >= DATEADD(month, -{{ RecencyMonths.value }}, CURRENT_DATE())
  AND CASE
        WHEN d.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN d.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN d.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN d.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN d.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END IS NOT NULL
  {{#DealType.value}} AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
GROUP BY 1, 2
ORDER BY 4 DESC;
