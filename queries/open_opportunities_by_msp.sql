-- Open Opportunities, by MSP -- Kevin: "in pipeline tab i want to show pipeline by msp as
-- well." Same shape and same two fixes as open_opportunities_by_segment.sql (read that
-- file's header for the full writeup) -- staleness via real Task/Meeting activity instead of
-- UPDATED_AT_UTC, same {{ RecencyMonths.value }} (default 3).
--
-- MSP FIELD CHOICE -- checked two candidates live:
--   1. FCT_CRM_OPPORTUNITY.PARTNER_MANAGEMENT_SOFTWARE (deal-level, used here) -- confirmed the
--      multi-value dirtiness that made performance_cube.sql drop this field for CLOSED deals is
--      a non-issue on OPEN deals (only ~6 "RealPage;Yardi"-style rows out of 10,720). The real
--      issue here is coverage, not dirtiness: 9,051 of 10,720 open opps (84%) have this NULL.
--   2. DIM_CRM_ACCOUNT_HISTORY.PROPERTY_MANAGEMENT_SOFTWARES (account-level) -- checked as a
--      potential backfill for the NULLs above, rejected: only matches 4,563 of 10,720 open opps
--      at all (57% join-miss), and still carries the same multi-value dirty rows. Not clearly
--      better, and adds a second dirty field instead of fixing the first.
--   Kept (1) and surfaced the NULL bucket honestly as "Not Set" (same principle as segment_
--   bucket's Not Set) rather than trying to backfill it with a field that has its own problems.
--   The 84% NULL rate itself is a real, useful fact for Sham -- most open pipeline doesn't have
--   an MSP identified yet, which is exactly the kind of thing a PN Ops/SDR data-hygiene push
--   could target, not something to hide by forcing a guess.
--
-- Excludes segment_bucket = NULL (DSMB/Partner/SDR/leadership pods), same team-attribution fix
-- as open_opportunities_by_segment.sql (OWNER_SK -> DIM_EMPLOYEE_HISTORY.TEAM_NAME, NOT the
-- batch-lagged STATIC_TEAM_NAME) -- MSP is a second cut on the SAME underlying open-pipeline
-- population, so it inherits the same base filters for consistency between the two views.
--
-- LEGACY HUBSPOT-ORIGIN RECORDS EXCLUDED (added 2026-07-29) -- same fix as
-- open_opportunities_by_segment.sql, see open_opportunities_drilldown.sql's header for the
-- full writeup. `OPPORTUNITY_ID LIKE '006%'` added directly rather than relying on the
-- staleness filter alone to catch every legacy record.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo (not currently an
-- issue for MSP values, but {{Segment.value}}/{{DealType.value}} below still carry it).

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
    COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set') AS msp,
    COUNT(*)                                            AS open_opportunities,
    SUM(o.FLEX_UNIT_COUNT)                              AS open_pipeline_units
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY d ON o.OWNER_SK = d.EMPLOYEE_SK AND d.IS_CURRENT = TRUE
LEFT JOIN last_activity la ON o.CRM_ACCOUNT_SK = la.CRM_ACCOUNT_SK
WHERE NOT o.IS_CLOSED
  AND o.OPPORTUNITY_ID LIKE '006%'
  -- New Vertical excluded repo-wide per Kevin 2026-08-05, see open_opportunities_by_segment.sql
  AND o.OPPORTUNITY_TYPE != 'New Vertical'
  AND COALESCE(la.last_activity_date, o.CREATED_AT_UTC) >= DATEADD(month, -{{ RecencyMonths.value }}, CURRENT_DATE())
  AND CASE
        WHEN d.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN d.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN d.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN d.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN d.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END IS NOT NULL
  {{#Segment.value}}  AND CASE
        WHEN d.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN d.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN d.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN d.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN d.TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END = '{{Segment.value}}' {{/Segment.value}}
  {{#DealType.value}} AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
GROUP BY 1
ORDER BY 3 DESC;
