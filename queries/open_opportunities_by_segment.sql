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
-- Excludes segment_bucket = NULL (DSMB/Partner/SDR/leadership pods), same as every other
-- query in this repo -- confirmed live this bucket alone carries 1,148 open opps / 2.19M
-- units, real volume that shouldn't get silently folded into a real segment's count.
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
LEFT JOIN last_activity la ON o.CRM_ACCOUNT_SK = la.CRM_ACCOUNT_SK
WHERE NOT o.IS_CLOSED
  AND COALESCE(la.last_activity_date, o.CREATED_AT_UTC) >= DATEADD(month, -{{ RecencyMonths.value }}, CURRENT_DATE())
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
