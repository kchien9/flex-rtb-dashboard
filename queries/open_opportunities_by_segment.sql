-- Open Opportunities, by Segment -- feeds the Pipeline tab per Kevin: "can we segment the
-- open opportunities? to see how many open opportunities each segment has? opps that havent
-- been touched in months can be excluded." Folded into Pipeline (not its own Opportunities
-- tab) per Kevin's own call -- this is a forward-looking pipeline-composition question, same
-- theme as the rest of that tab.
--
-- STALENESS FILTER -- there's no dedicated "last activity/last touched" field on
-- FCT_CRM_OPPORTUNITY, only UPDATED_AT_UTC (same situation as the Watch List recency fix,
-- which used the equivalent field on the Implementation table). Same caveat applies here:
-- this may reflect automated record syncs, not necessarily a real human touching the deal --
-- treat it as the best available proxy, not a precise "last activity" signal.
-- {{ RecencyMonths.value }} (default 3) controls the cutoff.
--
-- Validated live 2026-07-28: most open pipeline IS recently touched (no segment has a
-- meaningful ">12 months stale" bucket), so this filter mostly matters for "Not Set" (235
-- opps / 332,691 units sitting untouched 3-12 months, the largest stale pile of any segment
-- -- consistent with "Not Set" being messier elsewhere in this repo too) rather than
-- dramatically shrinking the other segments.
--
-- Excludes segment_bucket = NULL (DSMB/Partner/SDR/leadership pods), same as every other
-- query in this repo -- confirmed live this bucket alone carries 1,148 open opps / 2.19M
-- units, real volume that shouldn't get silently folded into a real segment's count.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.

SELECT
    CASE
        WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN o.STATIC_TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END                                AS segment_bucket,
    COUNT(*)                           AS open_opportunities,
    SUM(o.FLEX_UNIT_COUNT)             AS open_pipeline_units
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
WHERE NOT o.IS_CLOSED
  AND o.UPDATED_AT_UTC >= DATEADD(month, -{{ RecencyMonths.value }}, CURRENT_DATE())
  AND CASE
        WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
        WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
        WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
        WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
        WHEN o.STATIC_TEAM_NAME IS NULL THEN 'Not Set'
        ELSE NULL
    END IS NOT NULL
  {{#DealType.value}} AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
GROUP BY 1
ORDER BY 3 DESC;
