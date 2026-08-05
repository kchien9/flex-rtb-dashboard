-- Rep Diligence -- Average Days Since Last Touch, per rep, across their current open
-- pipeline. Kevin: "the days since last touch gave me an idea - can we have like an avg days
-- since last touched as an individual performance metric? basically we see like x rep on avg
-- goes 10 days between touching his accounts vs this rep only 3. this rep is a lot more
-- diligent w his accounts."
--
-- Reuses the exact last-touch definition already validated in
-- open_opportunities_drilldown.sql (MAX of completed Task/Meeting dates on the account,
-- falling back to CREATED_AT_UTC when an opportunity has never had any activity logged) --
-- same underlying population (open opportunities), aggregated to rep grain instead of listed
-- opportunity by opportunity. Same legacy-record exclusion (OPPORTUNITY_ID LIKE '006%' --
-- HubSpot-origin records have no valid Salesforce anchor, see that file's header for the full
-- writeup of the bug this fixes).
--
-- REP RESOLUTION -- same as open_opportunities_drilldown.sql: OWNER_SK -> DIM_EMPLOYEE_HISTORY
-- with NO SOURCE_SYSTEM restriction (that file's header confirms OWNER_SK on OPEN deals is
-- mostly HubSpot-sourced, not Salesforce -- restricting to 'salesforce' here would blank out
-- most owners, unlike the CLOSED-deal rep resolution in closed_lost_analysis.sql Part C /
-- closed_lost_rate_cube.sql, which correctly does restrict to salesforce). Team/segment and
-- departure grace period resolved from STG_SALESFORCE__USER by EMAIL, same canonical dedup
-- pattern as rep_leaderboard.sql.
--
-- MATERIALITY FLOOR ON OPEN-OPP COUNT, NOT DAYS -- a rep with 1-2 open opps can look
-- artificially "super diligent" or "very negligent" off a single data point that says nothing
-- about their real pattern. `{{ MinOpenOppsFloor.value }}` (validate against real distribution
-- before shipping).
--
-- MEDIAN SHOWN ALONGSIDE AVG, SAME REASON AS insights_deal_size_trend.sql -- checked live
-- before shipping: one very old, probably-stuck deal can drag a rep's average up hard even if
-- most of their book is being touched regularly. `median_days_since_last_touch` and
-- `max_days_since_last_touch` both shown so a high average driven by one outlier deal doesn't
-- read as uniformly poor cadence across the whole book.

WITH user_dedup AS (
    SELECT EMAIL, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
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
),
scoped AS (
    SELECT
        o.OPPORTUNITY_ID,
        e.FULL_NAME                                                                        AS rep,
        u.TEAM_NAME, u.PARENT_TEAM, u.IS_ACTIVE, u.LAST_LOGIN_AT_UTC,
        DATEDIFF(day, COALESCE(la.last_activity_date, o.CREATED_AT_UTC), CURRENT_DATE())    AS days_since_last_touch
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    LEFT JOIN user_dedup u ON u.EMAIL = e.EMAIL
    LEFT JOIN last_activity la ON o.CRM_ACCOUNT_SK = la.CRM_ACCOUNT_SK
    WHERE NOT o.IS_CLOSED
      AND o.OPPORTUNITY_ID LIKE '006%'
      AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
),
with_bucket AS (
    SELECT *,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
            WHEN TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM scoped
)
SELECT
    rep,
    team_bucket,
    segment_bucket,
    COUNT(*)                                            AS open_opps,
    ROUND(AVG(days_since_last_touch), 1)                AS avg_days_since_last_touch,
    MEDIAN(days_since_last_touch)                       AS median_days_since_last_touch,
    MAX(days_since_last_touch)                          AS max_days_since_last_touch
FROM with_bucket
WHERE segment_bucket IS NOT NULL
  AND rep IS NOT NULL
  AND (IS_ACTIVE OR LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
  {{#Team.value}}    AND team_bucket = '{{Team.value}}'       {{/Team.value}}
  {{#Segment.value}} AND segment_bucket = '{{Segment.value}}' {{/Segment.value}}
GROUP BY 1, 2, 3
HAVING open_opps >= {{ MinOpenOppsFloor.value }}
ORDER BY avg_days_since_last_touch DESC;
