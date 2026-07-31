-- Rep Detail -- the drill-through from Rep Leaderboard Kevin asked for: "trends across msp,
-- trends across deal types, insights on their units trending like we had before, trends on
-- their activities, and how many of their accounts in their book of business they're
-- touching... this is the section where we can dig into performance and what's driving it and
-- are they doing the right activities and what behaviors they have."
--
-- WHERE THIS LIVES -- deliberately NOT inline in the manager-pod rollup (would make that view
-- dense and defeat its job of staying scannable) and NOT its own top-level tab (it only makes
-- sense once a specific rep is already chosen, not a landing destination on its own). This is
-- a drill-through from Rep Leaderboard -- click a rep, this is what opens. Requires
-- {{ Rep.value }} to be set; not meant to run unfiltered.
--
-- Five parts, one rep at a time, all trended over {{ LookbackMonths.value }} months (default 6):
--   A. Units trend (rolled-out, same basis as rolled_out_units_cube.sql/rep_leaderboard.sql)
--   B. MSP mix trend
--   C. Deal-type mix trend
--   D. Activity trend (calls/emails/meetings, monthly -- more than the this/last-month pair
--      activity_vs_outcome_by_rep.sql shows, a real multi-month trendline)
--   E. Book-of-business coverage trend -- NEW CONCEPT, built for this file specifically
--
-- BOOK OF BUSINESS -- uses DIM_CRM_ACCOUNT_HISTORY.OWNER_ID (a real Salesforce Account-level
-- owner assignment, distinct from OWNER_SK on individual deals) joined to
-- STG_SALESFORCE__USER.USER_ID. Checked live: ~50% of accounts (62,620 of 126,361) have a real
-- Salesforce-user OWNER_ID; the other half carry a legacy numeric ID from the pre-Salesforce
-- system that never got reassigned. That's NOT a join gap to fix -- checked what those IDs
-- actually resolve to and the biggest are literal placeholders ("Vacant Territory" 8,640
-- accounts, "Hubspot Integration" 7,647), not real reps whose accounts are hiding behind a
-- stale ID. Per Kevin: "forget about hubspot. we dont use hubspot anymore - everything shoulda
-- been migrated." So an account with a legacy owner ID genuinely isn't properly assigned to
-- anyone in the current system -- correctly excluded from every rep's book, not a lower bound
-- that needs resolving. `book_size` here is accurate, not an undercount. Coverage = accounts
-- with real Task/Meeting activity that specific month / book_size. Validated live: Cory
-- Baach's real book is 52 accounts, coverage jumped from ~21-23% (Apr-Jun) to 79% (Jul) -- a
-- real, meaningful behavior change, exactly the "what behaviors do they have" signal Kevin
-- asked for.
--
-- Units/MSP/deal-type parts use HUBSPOT_DEAL_OWNER (name-string match, same basis as
-- rep_leaderboard.sql) rather than OWNER_SK -- consistent with every other rolled-out-units
-- query in this repo, and avoids re-deriving a different rep-identity join per part.
--
-- DSMB EXCLUSION ADDED 2026-07-31 (Parts A/B/C only) -- these sum PROPERTY_UNIT_COUNT and
-- should tie back to rep_leaderboard.sql's own (already DSMB-excluded) total for the same rep;
-- caught in a repo-wide DSMB audit. Parts D/E (activity, book-of-business) are NOT unit totals
-- -- a DSMB account is still legitimately part of a rep's real book/activity, same exemption
-- as activities_by_segment.sql -- left unchanged.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
-- Part A: units trend
SELECT
    s.BP_MONTH,
    SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated_units
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
WHERE s.HUBSPOT_DEAL_OWNER = '{{ Rep.value }}'
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
GROUP BY 1
ORDER BY 1;

-- Part B: MSP mix trend
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
SELECT
    s.BP_MONTH,
    s.PMS AS msp,
    SUM(s.PROPERTY_UNIT_COUNT) AS units
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
WHERE s.HUBSPOT_DEAL_OWNER = '{{ Rep.value }}'
  AND s.IS_NEW_INTEGRATED
  AND s.PMS IS NOT NULL
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
GROUP BY 1, 2
ORDER BY 1, 2;

-- Part C: deal-type mix trend
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
SELECT
    s.BP_MONTH,
    s.HUBSPOT_DEAL_TYPE AS deal_type,
    SUM(s.PROPERTY_UNIT_COUNT) AS units
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
WHERE s.HUBSPOT_DEAL_OWNER = '{{ Rep.value }}'
  AND s.IS_NEW_INTEGRATED
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
GROUP BY 1, 2
ORDER BY 1, 2;

-- Part D: activity trend (calls/emails/meetings/demos, monthly)
WITH emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, FULL_NAME
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
rep AS (
    SELECT ed.EMPLOYEE_SK
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.FULL_NAME = '{{ Rep.value }}'
),
tasks AS (
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails
    FROM FLEX.SALES.FCT_CRM_TASK t
    JOIN rep r ON t.EMPLOYEE_SK = r.EMPLOYEE_SK
    WHERE t.TASK_STATUS = 'completed'
      AND t.COMPLETED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
    GROUP BY 1
),
meets AS (
    SELECT DATE_TRUNC('month', mt.STARTED_AT_UTC) AS mo,
        COUNT(DISTINCT IFF(mt.MEETING_SUBTYPE = 'Sales | Demo', mt.MEETING_ID, NULL)) AS demos,
        COUNT(DISTINCT mt.MEETING_ID)                                                 AS meetings
    FROM FLEX.SALES.FCT_CRM_MEETING mt
    JOIN rep r ON mt.EMPLOYEE_SK = r.EMPLOYEE_SK
    WHERE mt.MEETING_STATUS = 'completed'
      AND mt.STARTED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
    GROUP BY 1
)
SELECT
    COALESCE(tk.mo, mt.mo)      AS mo,
    COALESCE(tk.calls, 0)       AS calls,
    COALESCE(tk.emails, 0)      AS emails,
    COALESCE(mt.meetings, 0)    AS meetings,
    COALESCE(mt.demos, 0)       AS demos
FROM tasks tk
FULL OUTER JOIN meets mt ON tk.mo = mt.mo
ORDER BY 1;

-- Part E: book-of-business coverage trend
WITH book AS (
    SELECT a.CRM_ACCOUNT_SK
    FROM FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a
    JOIN FLEX.STG_SALESFORCE.STG_SALESFORCE__USER u ON a.OWNER_ID = u.USER_ID
    WHERE a.IS_CURRENT = TRUE AND u.FULL_NAME = '{{ Rep.value }}'
),
activity AS (
    SELECT CRM_ACCOUNT_SK, activity_date FROM (
        SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
        UNION ALL
        SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
    )
),
months AS (
    SELECT DATEADD(month, -SEQ4(), DATE_TRUNC('month', CURRENT_DATE())) AS mo
    FROM TABLE(GENERATOR(ROWCOUNT => {{ LookbackMonths.value }} + 1))
)
SELECT
    m.mo,
    (SELECT COUNT(*) FROM book)                    AS book_size,
    COUNT(DISTINCT a.CRM_ACCOUNT_SK)                AS accounts_touched,
    DIV0(COUNT(DISTINCT a.CRM_ACCOUNT_SK), (SELECT COUNT(*) FROM book)) AS coverage_pct
FROM months m
LEFT JOIN book b ON TRUE
LEFT JOIN activity a ON a.CRM_ACCOUNT_SK = b.CRM_ACCOUNT_SK AND DATE_TRUNC('month', a.activity_date) = m.mo
GROUP BY 1
ORDER BY 1;
