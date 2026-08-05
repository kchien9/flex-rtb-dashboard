-- SDR Touches-Per-Lead + Lead Response Time, by segment -- two of the stat tiles Kevin asked
-- for on the SDR funnel section. No distinct Salesforce "Lead" object confirmed in this
-- warehouse -- approximated the same way sales_cycle_time_by_segment.sql/insights_cycle_time_
-- trend.sql already approximate "first touch" on an account: MIN(completed Task/Meeting date)
-- on the account, same technique, not re-derived.
--
-- POPULATION: accounts whose New Logo opportunity was CREATED in the period, scoped to
-- accounts with at least one completed activity from an SDR (same sdr_segment pod mapping as
-- sdr_funnel_by_segment.sql/sdr_activity_to_pipeline.sql) -- this is "how is the SDR pod doing
-- at responding to and working new leads," not a company-wide average across every touch.
--
-- lead_response_time_days = days from the account's FIRST SDR touch to the New Logo
-- opportunity's CREATED_AT_UTC -- "how long from first contact to a real qualified
-- opportunity," the closest honest proxy to "lead response time" without a real Lead object.
-- touches_per_lead = COUNT of completed SDR touches on that account, up to the opportunity's
-- creation date (not the whole account's lifetime history, which would double count touches
-- on unrelated prior deals).
--
-- MEDIAN SHOWN ALONGSIDE AVG, SAME REASON AS rep_touch_diligence.sql/insights_deal_size_
-- trend.sql -- check live before trusting avg alone -- one outlier account can skew it.
--
-- Same DSMB exclusion, same New-Logo-only scope as sdr_funnel_by_segment.sql.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, TEAM_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
sdr_emp AS (
    SELECT ed.EMPLOYEE_SK,
        CASE
            WHEN u.TEAM_NAME = 'SMB SDRs' THEN 'SMB'
            WHEN u.TEAM_NAME = 'MM/Enterprise SDRs' THEN 'MM/Ent'
            WHEN u.TEAM_NAME = 'Strategic SDRs' THEN 'Strategic'
            ELSE NULL
        END AS sdr_segment
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
sdr_touches AS (
    SELECT CRM_ACCOUNT_SK, activity_date, sdr_segment FROM (
        SELECT t.CRM_ACCOUNT_SK, t.COMPLETED_AT_UTC AS activity_date, e.sdr_segment
        FROM FLEX.SALES.FCT_CRM_TASK t
        JOIN sdr_emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
        WHERE t.TASK_STATUS = 'completed'
        UNION ALL
        SELECT m.CRM_ACCOUNT_SK, m.STARTED_AT_UTC, e.sdr_segment
        FROM FLEX.SALES.FCT_CRM_MEETING m
        JOIN sdr_emp e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
        WHERE m.MEETING_STATUS = 'completed'
    )
),
new_logo AS (
    SELECT o.OPPORTUNITY_ID, o.CRM_ACCOUNT_SK, o.CREATED_AT_UTC,
        DATE_TRUNC('month', o.CREATED_AT_UTC) AS mo
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.OPPORTUNITY_TYPE = 'New Logo'
      AND o.CREATED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
),
per_opp AS (
    SELECT
        nl.mo, st.sdr_segment,
        nl.OPPORTUNITY_ID,
        MIN(st.activity_date)                                                    AS first_touch,
        DATEDIFF(day, MIN(st.activity_date), nl.CREATED_AT_UTC)                  AS lead_response_time_days,
        COUNT(IFF(st.activity_date <= nl.CREATED_AT_UTC, 1, NULL))               AS touches_before_opp_created
    FROM new_logo nl
    JOIN sdr_touches st ON st.CRM_ACCOUNT_SK = nl.CRM_ACCOUNT_SK
    GROUP BY 1, 2, 3, nl.CREATED_AT_UTC
    HAVING lead_response_time_days >= 0
)
SELECT
    mo AS month,
    sdr_segment AS segment,
    COUNT(*)                                              AS new_logo_opps_with_sdr_touch,
    ROUND(AVG(lead_response_time_days), 1)                AS avg_lead_response_time_days,
    MEDIAN(lead_response_time_days)                        AS median_lead_response_time_days,
    ROUND(AVG(touches_before_opp_created), 1)             AS avg_touches_per_lead,
    MEDIAN(touches_before_opp_created)                     AS median_touches_per_lead
FROM per_opp
WHERE sdr_segment IS NOT NULL
GROUP BY 1, 2
HAVING new_logo_opps_with_sdr_touch >= {{ MinOppsFloor.value }}
ORDER BY segment, month;
