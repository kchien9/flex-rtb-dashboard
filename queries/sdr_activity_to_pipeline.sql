-- SDR Activity -> Pipeline, by Segment -- Kevin: "we need to layer in sdrs now. and see how
-- sdr activities leads to pipeline." Lives on the new Activities tab alongside
-- activities_by_segment.sql (now role-split) and activities_by_team.sql. A trended,
-- segment-grain view: SDR calls (and SDR headcount, see below) next to New Logo pipeline
-- created in that segment, over the trailing {{ LookbackMonths.value }} months (default 6),
-- so Sham can see whether a change in SDR activity precedes a change in pipeline creation.
--
-- CORRELATION, NOT ATTRIBUTION -- re-validated live 2026-07-31: of New Logo opportunities
-- created in the trailing 6 months, only 11.3% resolve SDR_SK to a real named SDR (the rest
-- are a placeholder "none" record) -- too sparse to build a per-SDR "this rep sourced this
-- pipeline" view. Same fix the now-deprecated full_funnel_by_segment.sql already used and
-- validated: correlate SDR-POD activity against AE-SEGMENT pipeline (e.g. all of Strategic
-- SDRs' calls vs. all New Logo pipeline created in the Strategic segment), not a claim that
-- any specific SDR sourced any specific deal.
--
-- PIPELINE_CREATED IS NEW LOGO ONLY, DELIBERATELY -- Expansion/Move In pipeline is an
-- existing-account motion (an AE or PSM working an account that's already a customer), not
-- something an SDR's outbound/inbound-qualifying work would plausibly source. Blending them in
-- would dilute a real correlation with pipeline SDRs had nothing to do with.
--
-- SDR HEADCOUNT TRANSPARENCY -- carried over from full_funnel_by_segment.sql's real finding:
-- Strategic SDRs is ONE person (Louis Trujillo), period -- that segment's "SDR calls" column is
-- literally his individual activity, not a team signal (his PTO or a bad day reads as
-- "Strategic SDR activity collapsed" without this context). MM/Enterprise SDRs = 3, SMB SDRs =
-- 7 (re-verify headcount before presenting, roster changes). `sdr_headcount` = COUNT DISTINCT
-- SDRs who logged at least one call that month, not the pod's static roster size -- so a
-- 1-person column is visibly different from a 7-person one wherever this is displayed.
--
-- DSMB EXCLUSION on pipeline_created -- SDR calls have no PMC/account-size link (same exemption
-- as activities_by_segment.sql), but a handful of DSMB-sized deals could still inflate the
-- pipeline_created COUNT, so the standard pmc_size join is applied there, matching the
-- repo-wide DSMB audit completed 2026-07-31 (see README's "must-fix items" #3).
--
-- Same dedup + departure-grace-period pattern as everywhere else in this repo.

WITH months AS (
    SELECT DATEADD(month, -SEQ4(), DATE_TRUNC('month', CURRENT_DATE())) AS mo
    FROM TABLE(GENERATOR(ROWCOUNT => {{ LookbackMonths.value }} + 1))
),
pmc_size AS (
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
    SELECT EMAIL, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
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
        END AS sdr_segment,
        CASE
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
            WHEN u.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS ae_segment
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
sdr_calls AS (
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo, e.sdr_segment AS segment,
        COUNT(DISTINCT t.TASK_ID) AS sdr_calls,
        COUNT(DISTINCT t.EMPLOYEE_SK) AS sdr_headcount
    FROM FLEX.SALES.FCT_CRM_TASK t
    JOIN emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    WHERE t.TASK_STATUS = 'completed' AND t.TASK_TYPE = 'call'
      AND t.COMPLETED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2
),
pipeline_created AS (
    SELECT DATE_TRUNC('month', o.CREATED_AT_UTC) AS mo, e.ae_segment AS segment,
        COUNT(DISTINCT o.OPPORTUNITY_ID) AS new_logo_pipeline_created
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    JOIN emp e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.ae_segment IS NOT NULL
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.OPPORTUNITY_TYPE = 'New Logo'
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      AND o.CREATED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2
),
-- segment spine, explicit -- SDR pods only cover these 3 segments, and cross-joining months x
-- segments (rather than relying on sc/pc happening to have a row) avoids silently dropping a
-- month where one segment had zero SDR calls or zero pipeline created that month.
segments AS (
    SELECT 'Strategic' AS segment UNION ALL SELECT 'MM/Ent' UNION ALL SELECT 'SMB'
),
spine AS (
    SELECT m.mo, s.segment FROM months m CROSS JOIN segments s
)
SELECT
    sp.mo,
    sp.segment,
    COALESCE(sc.sdr_calls, 0)                 AS sdr_calls,
    COALESCE(sc.sdr_headcount, 0)              AS sdr_headcount,
    COALESCE(pc.new_logo_pipeline_created, 0) AS new_logo_pipeline_created
FROM spine sp
LEFT JOIN sdr_calls sc ON sp.mo = sc.mo AND sp.segment = sc.segment
LEFT JOIN pipeline_created pc ON sp.mo = pc.mo AND sp.segment = pc.segment
ORDER BY sp.segment, sp.mo;
