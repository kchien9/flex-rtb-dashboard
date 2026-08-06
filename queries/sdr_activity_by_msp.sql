-- SDR Activity, by MSP -- Box 2's SDR Activity Subject, MSP breakout. SDR pods (SMB/MM-Ent/
-- Strategic) map to segments, not MSPs -- this file answers a different question ("are SDRs
-- spending time on AppFolio prospects vs. Yardi prospects") by joining activity through the
-- ACCOUNT the SDR touched, not through the SDR's own pod assignment.
--
-- Same account-level MSP field as niro_units_cube.sql (DIM_SALES_ACCOUNTS.ACCOUNT_PROPERTY_
-- MANAGEMENT_SOFTWARES). JOIN KEY FIX FROM THE PLAN'S DRAFT SQL -- confirmed live 2026-08-06:
-- DIM_CRM_ACCOUNT_HISTORY has no ACCOUNT_SALESFORCE_ID column (it's ACCOUNT_ID, which mixes
-- Salesforce-format and HubSpot-format ids depending on SOURCE_SYSTEM -- confirmed by sampling
-- rows). Joining ACCOUNT_ID to DIM_SALES_ACCOUNTS.ACCOUNT_SALESFORCE_ID alone only matched
-- 49.6% of current accounts -- OR'ing in ACCOUNT_HUBSPOT_ID = ACCOUNT_ID raised that to 99.99%
-- (126,667 of 126,675 current accounts resolved to a real DIM_SALES_ACCOUNTS row, re-verified
-- 2026-08-06 by counting matched acct rows directly rather than a single nullable acct column).
-- Checked for fan-out from the OR: only 1 of 126,674 CRM_ACCOUNT_SK values matches more than
-- one DIM_SALES_ACCOUNTS row -- negligible, not a real fan-out risk.
--
-- SDR ACTIVITY x TEAM DELIBERATELY NOT BUILT -- see docs/superpowers/specs/2026-08-05-debrief-
-- restructure-design.md: SDR pods don't map 1:1 to the 4 AE teams (2 SMB teams share one SDR
-- pod), so there's no clean by-team cut for SDR data. Don't add one without a real re-mapping
-- of the SDR org structure first.
--
-- Same DSMB exclusion, same completed-task/meeting-held definitions, same departure grace
-- period as sdr_funnel_by_segment.sql.
--
-- VALIDATED LIVE 2026-08-06 (GraceMonths=3, LookbackMonths=6): 22 real MSP names appear
-- (Yardi, RealPage, AppFolio, Entrata, MRI, etc, by call volume) plus 'Not Set' for unresolved
-- accounts -- the join is not broken. NOTE: unresolved-MSP calls are NOT dropped by this file,
-- they're bucketed into 'Not Set' and kept, so the only source of drop-off vs.
-- sdr_funnel_by_segment.sql is the DSMB/750-unit exclusion that file's own activity CTE
-- doesn't apply (only its pipeline CTE does). Actual measured drop-off is small: July 2026
-- (most recent full month) calls = 8,569 here vs. 8,794 in sdr_funnel_by_segment.sql, i.e.
-- 97.4% retained (2.6% lost to DSMB exclusion). Feb/Mar 2026 matched exactly (0% loss) -- the
-- gap grows to ~3.2% by August as small-PMC call volume rises -- all well under the 50%-loss
-- concern threshold, confirms no join problem.

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
emp AS (
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
acct_msp AS (
    SELECT a.CRM_ACCOUNT_SK, acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS msp, a.PMC_ID
    FROM FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON acct.ACCOUNT_SALESFORCE_ID = a.ACCOUNT_ID OR acct.ACCOUNT_HUBSPOT_ID = a.ACCOUNT_ID
    WHERE a.IS_CURRENT = TRUE
),
activity AS (
    -- msp COALESCE'd to 'Not Set' here, not in the final SELECT -- same convention as
    -- insights_mix_shift_scanner.sql. Caught live: coalescing only in the final SELECT leaves
    -- am.msp as NULL going into the FULL OUTER JOIN below, and NULL = NULL never matches in
    -- SQL, so unresolved-MSP activity and unresolved-MSP meetings would land as two separate
    -- 'Not Set' rows per month instead of one merged row.
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo, COALESCE(am.msp, 'Not Set') AS msp,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL)) AS calls
    FROM FLEX.SALES.FCT_CRM_TASK t
    JOIN emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    LEFT JOIN acct_msp am ON am.CRM_ACCOUNT_SK = t.CRM_ACCOUNT_SK
    LEFT JOIN pmc_size ps ON am.PMC_ID = ps.PMC_ID
    WHERE t.TASK_STATUS = 'completed'
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      AND t.COMPLETED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2
),
meetings AS (
    -- Same 'Not Set' COALESCE-before-join fix as activity above.
    SELECT DATE_TRUNC('month', m.CREATED_AT_UTC) AS mo, COALESCE(am.msp, 'Not Set') AS msp,
        COUNT(*) AS meetings_booked,
        SUM(IFF(m.MEETING_STATUS = 'completed', 1, 0)) AS meetings_held
    FROM FLEX.SALES.FCT_CRM_MEETING m
    JOIN emp e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    LEFT JOIN acct_msp am ON am.CRM_ACCOUNT_SK = m.CRM_ACCOUNT_SK
    LEFT JOIN pmc_size ps ON am.PMC_ID = ps.PMC_ID
    WHERE (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      AND m.CREATED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2
)
SELECT
    COALESCE(a.mo, mt.mo) AS month,
    COALESCE(a.msp, mt.msp, 'Not Set') AS msp,
    COALESCE(a.calls, 0) AS calls,
    COALESCE(mt.meetings_booked, 0) AS meetings_booked,
    COALESCE(mt.meetings_held, 0) AS meetings_held,
    LAG(COALESCE(a.calls, 0)) OVER (PARTITION BY COALESCE(a.msp, mt.msp, 'Not Set') ORDER BY COALESCE(a.mo, mt.mo)) AS calls_prior_period,
    AVG(COALESCE(a.calls, 0)) OVER (PARTITION BY COALESCE(a.msp, mt.msp, 'Not Set') ORDER BY COALESCE(a.mo, mt.mo) ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS calls_trailing_avg_6mo
FROM activity a
FULL OUTER JOIN meetings mt ON a.mo = mt.mo AND a.msp = mt.msp
ORDER BY msp, month;
