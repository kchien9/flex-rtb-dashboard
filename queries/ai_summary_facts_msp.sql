-- AI Summary Facts, MSP tab -- Kevin: "lets add an ai msp summary that pulls out trends for
-- him to read." Same architecture and same scope discipline as ai_summary_facts.sql (see that
-- file's header and docs/superblocks-setup.md's AI Summary section) -- this query gathers
-- facts, a downstream LLM step narrates them, never the other way around.
--
-- WHY THIS IS A SEPARATE FILE, NOT JUST ai_summary_facts.sql WITH {{Msp.value}} SET --
-- ai_summary_facts.sql already reflects whichever ONE MSP is currently filtered (its Msp
-- parameter). What's missing for an MSP-TAB summary specifically is a CROSS-MSP comparison --
-- which MSP moved the most, up or down, this period -- so the summary can say "AppFolio down
-- 16%, RealPage down 46%, ResMan up 2.7x" instead of only ever describing whichever single MSP
-- happens to be selected. Part A below returns EVERY MSP side by side for exactly this reason.
--
-- Validated live 2026-07-29, this vs. last BP month, DSMB-excluded, all segments: Yardi +10%
-- (88,236 -> 97,132), AppFolio -16% (58,488 -> 49,234), RealPage -46% (31,913 -> 17,209),
-- Entrata +41%, ResMan +2.7x (small base -- 2,540 -> 9,418), Rentmanager -74% (also small
-- base). SAME SMALL-BASE CAVEAT AS EVERYWHERE ELSE IN THIS REPO -- a %-change on a low-volume
-- MSP (ResMan, Rentmanager, Aptexx, AMC Rent Pay) swings huge on small absolute moves -- the
-- LLM narration should lead with the large-base MSPs (Yardi/AppFolio/RealPage) and mention
-- small-base swings as a footnote with the actual unit counts shown, not just the %, so "+2.7x"
-- doesn't read as more dramatic than a 6,878-unit move actually is.
--
-- Part B: same top_msp_share / concentration question as insights_mix_shift.sql, reused here
-- so the summary can say "no single MSP dominates" or "Yardi is now N% of new rollouts, up
-- from M% last period" without a human cross-referencing a second query.
--
-- Part C: which MSP explains the OVERALL this-vs-last swing the most, in absolute units --
-- same "top 3 drivers" idea as ai_summary_facts.sql Part B, axis is MSP instead of rep.

-- Part A: every MSP, this vs. last period, side by side.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.IS_NEW_INTEGRATED
      AND s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      {{#Segment.value}} AND segment_bucket = '{{Segment.value}}' {{/Segment.value}}
)
SELECT
    PMS AS msp,
    SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0)) AS this_period_units,
    SUM(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0)) AS last_period_units,
    DIV0(
        SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0))
        - SUM(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0)),
        SUM(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0))
    ) AS pct_change
FROM base
WHERE PMS IS NOT NULL
GROUP BY 1
ORDER BY this_period_units DESC;

-- Part B: MSP concentration -- top MSP's share of total new-rollout units, this vs. last
-- period. Same base as Part A.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT s.BP_MONTH, s.PMS, s.PROPERTY_UNIT_COUNT
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.IS_NEW_INTEGRATED AND s.PMS IS NOT NULL
      AND s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
by_month_msp AS (
    SELECT BP_MONTH, PMS, SUM(PROPERTY_UNIT_COUNT) AS msp_units
    FROM base GROUP BY 1, 2
),
month_total AS (
    SELECT BP_MONTH, SUM(PROPERTY_UNIT_COUNT) AS total_units
    FROM base GROUP BY 1
),
top_msp_per_month AS (
    SELECT * FROM by_month_msp
    QUALIFY msp_units = MAX(msp_units) OVER (PARTITION BY BP_MONTH)
)
SELECT
    IFF(t.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), 'this_period', 'last_period') AS period,
    t.PMS AS top_msp,
    t.msp_units,
    mt.total_units,
    DIV0(t.msp_units, mt.total_units) AS top_msp_share
FROM top_msp_per_month t
JOIN month_total mt ON t.BP_MONTH = mt.BP_MONTH
ORDER BY period DESC;

-- Part C: which MSP explains the overall this-vs-last swing the most, in absolute units --
-- lets the LLM say "driven mostly by RealPage" instead of just listing every MSP's %-change
-- with equal weight.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT s.BP_MONTH, s.PMS, s.PROPERTY_UNIT_COUNT
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.IS_NEW_INTEGRATED AND s.PMS IS NOT NULL
      AND s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
by_msp AS (
    SELECT
        PMS AS msp,
        SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0))
          - SUM(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0)) AS absolute_unit_change
    FROM base
    GROUP BY 1
)
SELECT
    msp,
    absolute_unit_change,
    DIV0(ABS(absolute_unit_change), SUM(ABS(absolute_unit_change)) OVER ()) AS share_of_total_swing
FROM by_msp
ORDER BY ABS(absolute_unit_change) DESC
LIMIT 3;
