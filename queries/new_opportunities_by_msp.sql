-- New Opportunities, by MSP -- Kevin: "should we also have a view on NEW open opps by MSP?
-- rather than just currently open?" Companion to open_opportunities_by_msp.sql -- that one
-- answers "what does the CURRENT open pipeline look like by MSP" (a stock view); this answers
-- "which MSPs are we sourcing NEW pipeline from" (a flow view). Different question, both
-- useful: the open-pipeline view can look MSP-heavy just because a few old deals never closed
-- out, while this one reflects actual recent sourcing.
--
-- "NEW" = OPPORTUNITY.CREATED_AT_UTC falls in the trailing {{ NewOppsMonths.value }} months
-- (default 1 = "this month"), regardless of whether the deal is still open today -- pipeline
-- CREATED in the window counts, even if it already closed won/lost since. This is deliberately
-- NOT "currently open AND created recently" -- that would undercount real sourcing by dropping
-- anything that closed fast.
--
-- MSP FIELD -- same choice and same reasoning as open_opportunities_by_msp.sql:
-- FCT_CRM_OPPORTUNITY.PARTNER_MANAGEMENT_SOFTWARE (deal-level), NULLs surfaced honestly as
-- "Not Set" rather than backfilled from the dirtier account-level field.
--
-- REAL FINDING while validating this (2026-07-30, live query, trailing 1 month): "Not Set"
-- is only 1 of ~865 new opportunities here, vs. 84% NULL on the CURRENTLY-OPEN view. MSP gets
-- captured reliably at creation time; the NULL rate on the open-pipeline view is almost
-- entirely OLD deals created before this field was being filled in consistently, not an
-- ongoing data-entry gap. Worth knowing before treating the 84% NULL number as a live process
-- problem to fix -- it's largely backlog, not a today issue.
--
-- Same team-attribution fix as open_opportunities_by_msp.sql (OWNER_SK ->
-- DIM_EMPLOYEE_HISTORY.TEAM_NAME, NOT the batch-lagged STATIC_TEAM_NAME on the opportunity
-- itself), same legacy-Hubspot-record exclusion (OPPORTUNITY_ID LIKE '006%'), same optional
-- Segment/DealType filters. No staleness/last-activity filter here -- that concept is specific
-- to the open-pipeline view (is a deal still being worked); every row here already qualifies
-- by having been CREATED in the window, so there's nothing to filter for freshness.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo (not currently an
-- issue for MSP values, but {{Segment.value}}/{{DealType.value}} below still carry it).

SELECT
    COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set') AS msp,
    COUNT(*)                                            AS new_opportunities,
    SUM(o.FLEX_UNIT_COUNT)                              AS new_pipeline_units
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY d ON o.OWNER_SK = d.EMPLOYEE_SK AND d.IS_CURRENT = TRUE
WHERE o.OPPORTUNITY_ID LIKE '006%'
  AND o.CREATED_AT_UTC >= DATEADD(month, -{{ NewOppsMonths.value }}, CURRENT_DATE())
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
