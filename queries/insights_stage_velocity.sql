-- Stage Velocity -- is deal-cycle time within a segment getting slower or faster, and which
-- specific deals are stuck right now. Two parts, same as the other insight queries: a
-- trend (segment x quarter) and a real-time watch list (individual stuck deals).
--
-- WITHIN-SEGMENT, NOT ACROSS SEGMENT -- Kevin's correction: comparing Strategic deal cycle
-- time to SMB deal cycle time is a bad comparison because Strategic deals are EXPECTED to
-- take longer (bigger deals, more stakeholders, longer legal review) -- that's structural, not
-- a problem. The actual question is "is THIS segment's cycle time changing over time" (e.g.
-- SMB negotiation deals taking 3x longer this quarter than last quarter) -- comparing a
-- segment against its own history, never against a different segment's baseline.
--
-- SEGMENT PROXY -- same issue as everywhere else in this repo: HUBSPOT_COMPANY_SEGMENT /
-- ACCOUNT_SEGMENT don't hold up against real account-size data (see rolled_out_units_cube.sql
-- header). On the new tables there's no verified segment field at all yet. Using
-- STATIC_TEAM_NAME (pod) as the segment proxy instead -- same logic as oneonone_prep.sql's
-- pod-based grouping, bucketed into SMB / DSMB / Strategic-MM. Pods not mapped to a real AE
-- segment (Partner Success, Rev Ops, Channel Sales, House Accounts, SDR-only pods) are
-- excluded, not lumped into "Other" -- their deals aren't comparable to segment-level AE cycle
-- time at all.
--
-- CENSORING BIAS -- the real trap here. If you compute "avg days in stage" including deals
-- STILL sitting in that stage (using CURRENT_DATE() as a stand-in end date), a quarter that
-- just started will always look artificially fast -- only quick deals have had time to resolve
-- yet, slow ones haven't hit their real duration. Part A below only includes RESOLVED
-- transitions (deal actually moved to the next stage) so quarter-over-quarter comparisons are
-- apples to apples. Part B (currently-stuck) is the deliberate complement -- it's the only
-- place open-ended elapsed time belongs.
--
-- DATA QUALITY -- validated live 2026-07-27: a handful of NEGOTIATION_AT_UTC values are in the
-- future (entered_q = 2026-10 while today is 2026-07-27) -- almost certainly bad data entry,
-- not real. Harmless to Part A (future quarters just show as a tiny separate bucket, easy to
-- ignore), but don't be surprised if Superblocks shows a stray future-dated row.
-- Also found: several of Part B's longest-stuck deals belong to reps already confirmed
-- departed in oneonone_prep.sql (Jacob Fidler, Redding Tews) -- these are zombie deals nobody
-- closed out, not live 800-day negotiations.
--
-- BUILT NOW (2026-07-29), per Kevin's sweeping "dont just fix this in this query it needs to
-- be fixed everywhere. i dont want to see inactive... in any table" -- same root cause and fix
-- as activity_vs_outcome_by_rep.sql's header. Part B's rep field now comes from a deduped,
-- grace-period-aware team_map (Salesforce-sourced DIM_EMPLOYEE_HISTORY row -> deduped
-- STG_SALESFORCE__USER, {{ GraceMonths.value }} grace period) instead of a raw
-- DIM_EMPLOYEE_HISTORY join -- a deal whose owner is departed beyond the grace window now
-- shows rep = NULL rather than a name, so the watch list still surfaces the stuck deal (it's
-- real, still needs someone to close it out) but doesn't claim a departed person is working it.

-- Part A: within-segment stage velocity trend, resolved transitions only
WITH segmented AS (
    SELECT
        OPPORTUNITY_ID,
        CASE
            WHEN STATIC_TEAM_NAME LIKE 'SMB Account Executives%' OR STATIC_TEAM_NAME = 'SMB Manager' THEN 'SMB'
            WHEN STATIC_TEAM_NAME LIKE 'Deep SMB%' OR STATIC_TEAM_NAME LIKE 'DSMB%' THEN 'DSMB'
            WHEN STATIC_TEAM_NAME IN ('Brandon''s Team','Cory''s Team') OR STATIC_TEAM_NAME LIKE 'Strategic%' OR STATIC_TEAM_NAME LIKE 'MM/Enterprise%' THEN 'Strategic/MM'
            ELSE NULL
        END AS segment,
        QUALIFICATION_AT_UTC, DISCOVERY_AT_UTC, BUILDING_VALUE_AT_UTC, NEGOTIATION_AT_UTC, DEAL_REVIEW_AT_UTC
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY
    WHERE CREATED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
),
transitions AS (
    SELECT segment, 'Qualification' AS stage, DATE_TRUNC('quarter', QUALIFICATION_AT_UTC) AS entered_q,
        QUALIFICATION_AT_UTC AS stage_start, DISCOVERY_AT_UTC AS stage_end FROM segmented
    UNION ALL
    SELECT segment, 'Discovery', DATE_TRUNC('quarter', DISCOVERY_AT_UTC),
        DISCOVERY_AT_UTC, BUILDING_VALUE_AT_UTC FROM segmented
    UNION ALL
    SELECT segment, 'Building Value', DATE_TRUNC('quarter', BUILDING_VALUE_AT_UTC),
        BUILDING_VALUE_AT_UTC, NEGOTIATION_AT_UTC FROM segmented
    UNION ALL
    SELECT segment, 'Negotiation', DATE_TRUNC('quarter', NEGOTIATION_AT_UTC),
        NEGOTIATION_AT_UTC, DEAL_REVIEW_AT_UTC FROM segmented
)
SELECT
    segment,
    stage,
    entered_q,
    COUNT(*)                                     AS resolved_deals,
    AVG(DATEDIFF(day, stage_start, stage_end))   AS avg_days_in_stage
FROM transitions
WHERE stage_start IS NOT NULL AND stage_end IS NOT NULL AND segment IS NOT NULL
  {{#Stage.value}} AND stage = '{{Stage.value}}' {{/Stage.value}}
GROUP BY 1, 2, 3
QUALIFY entered_q < DATE_TRUNC('quarter', CURRENT_DATE())  -- drop in-progress quarter, same censoring reason as above
ORDER BY 1, 2, 3;

-- Part B: currently-stuck deals -- open right now, longer in their current stage than
-- 1.5x their segment's trailing-90-day resolved average. Real validated example, Negotiation
-- stage: SMB baseline ~0.8 days (fast-moving pipeline), yet several SMB deals show 700+ days
-- still sitting in Negotiation -- clear zombie/stuck-deal signal, not noise.
WITH emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, FULL_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
rep_status AS (
    SELECT ed.EMPLOYEE_SK, u.FULL_NAME, u.IS_ACTIVE, u.LAST_LOGIN_AT_UTC
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
),
segmented AS (
    SELECT
        o.OPPORTUNITY_ID, o.OPPORTUNITY_NAME, o.FLEX_UNIT_COUNT, o.IS_CLOSED,
        o.NEGOTIATION_AT_UTC, o.DEAL_REVIEW_AT_UTC,
        CASE
            WHEN o.STATIC_TEAM_NAME LIKE 'SMB Account Executives%' OR o.STATIC_TEAM_NAME = 'SMB Manager' THEN 'SMB'
            WHEN o.STATIC_TEAM_NAME LIKE 'Deep SMB%' OR o.STATIC_TEAM_NAME LIKE 'DSMB%' THEN 'DSMB'
            WHEN o.STATIC_TEAM_NAME IN ('Brandon''s Team','Cory''s Team') OR o.STATIC_TEAM_NAME LIKE 'Strategic%' OR o.STATIC_TEAM_NAME LIKE 'MM/Enterprise%' THEN 'Strategic/MM'
            ELSE NULL
        END AS segment,
        -- departed-beyond-grace rep shows as NULL (no match, or inactive past the grace
        -- window) rather than a name -- the deal itself stays on the watch list, it just
        -- doesn't claim a departed person is actively working it
        IFF(r.FULL_NAME IS NULL OR r.IS_ACTIVE OR r.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()), r.FULL_NAME, NULL) AS rep
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN rep_status r ON o.OWNER_SK = r.EMPLOYEE_SK
    WHERE o.NEGOTIATION_AT_UTC IS NOT NULL AND o.NEGOTIATION_AT_UTC <= CURRENT_DATE()
),
baseline AS (
    SELECT segment, AVG(DATEDIFF(day, NEGOTIATION_AT_UTC, DEAL_REVIEW_AT_UTC)) AS avg_days
    FROM segmented
    WHERE DEAL_REVIEW_AT_UTC IS NOT NULL AND NEGOTIATION_AT_UTC >= DATEADD(day, -90, CURRENT_DATE())
    GROUP BY 1
)
SELECT
    s.OPPORTUNITY_NAME                                              AS opportunity,
    s.rep,
    s.segment,
    s.FLEX_UNIT_COUNT                                               AS units,
    DATEDIFF(day, s.NEGOTIATION_AT_UTC, CURRENT_DATE())             AS days_in_negotiation,
    ROUND(b.avg_days, 1)                                            AS segment_baseline_days
FROM segmented s
JOIN baseline b ON s.segment = b.segment
WHERE s.DEAL_REVIEW_AT_UTC IS NULL AND NOT s.IS_CLOSED AND s.segment IS NOT NULL
  AND DATEDIFF(day, s.NEGOTIATION_AT_UTC, CURRENT_DATE()) > 1.5 * NULLIF(b.avg_days, 0)
  {{#Segment.value}} AND s.segment = '{{Segment.value}}' {{/Segment.value}}
ORDER BY days_in_negotiation DESC;
