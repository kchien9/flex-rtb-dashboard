-- Net Units Bridge -- Kevin: "this is how we get to net units. so its new + recap -
-- deactivated + uplevel to integrated - downlevel to niro, then remaining net change is the
-- bucket where we cant really explain it." Matches an existing, already-validated
-- methodology Kevin uses elsewhere (a Sigma "Integrated Units [Full Month]" table) --
-- this file reproduces that exact bridge on this dashboard's own DSMB-excluded base, not a
-- new definition invented here.
--
-- WHY THIS MATTERS -- every rolled-out-units view in this dashboard up to this point
-- (rolled_out_units_cube.sql, ai_summary_facts.sql Part A, the decline-streak scanners) shows
-- GROSS ADDS ONLY (new + recaptured). None of them show DEACTIVATED units, so Sham could see
-- "248,699 units added, up 21%!" while churn is quietly accelerating underneath it and nothing
-- in this dashboard would say so. This file is the fix -- surfaces the full bridge, not just
-- the growth half of it.
--
-- VALIDATED LIVE AGAINST THE STOCK COLUMN -- cross-checked `new_integrated + deactivated +
-- recaptured + uplevel_to_integrated + downlevel_to_niro` against IS_INTEGRATED_TOTAL's own
-- month-over-month change (the ground truth). Reconciles within 1-4% every month, small
-- residual (`remaining_net_change`) same as Kevin's own reference table -- not a bug to chase
-- to zero, this is the expected "we can't fully attribute this sliver" bucket. Company-wide
-- 8-month check: residuals ran 1-4% of net change (Kevin's own reference table shows a similar
-- small residual, e.g. Jan ~1%) -- the modest gap vs. his exact numbers is most likely this
-- dashboard's DSMB exclusion (his source table is likely unfiltered/company-wide) -- a known,
-- deliberate difference in scope, not an error to reconcile away.
--
-- FLAGS USED, CONFIRMED LIVE TO EXIST ON PROPERTY_BP_MONTH_STATS: IS_NEW_INTEGRATED,
-- IS_DEACTIVATED, IS_RECAPTURED_NEW_ROLLOUT / IS_RECAPTURED_OTHER, IS_UPLEVEL_TO_INTEGRATED,
-- IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT (= "Downlevel to NIRO"), IS_INTEGRATED_TOTAL (the
-- stock column, used only as the cross-check ground truth, never summed across months itself).
--
-- Same DSMB exclusion (pmc_size, current live PMC total > 750) as every other file in this
-- repo.
--
-- GRANULARITY ADDED 2026-08-04 -- `{{ Granularity.value }}` = 'Month' | 'Quarter', same
-- DATE_TRUNC('quarter', BP_MONTH) technique as insights_declining_streaks.sql. `integrated_total`
-- for a quarter bucket takes the LAST month's stock value in that quarter, never summed across
-- months -- summing a STOCK column across 3 months would triple-count it, the exact stock-vs-
-- flow bug this repo has been burned by before. All the FLOW components (new_integrated,
-- deactivated, recaptured, etc.) sum correctly across the 3 months in a quarter.
--
-- BUG CAUGHT VALIDATING LIVE -- first draft used `MAX_BY(IFF(IS_INTEGRATED_TOTAL,
-- PROPERTY_UNIT_COUNT, 0), BP_MONTH)` directly inside the `bridge` CTE's single aggregation --
-- that picks ONE raw detail row's PROPERTY_UNIT_COUNT (whichever row happens to have the max
-- BP_MONTH), not the real SUMMED monthly stock total -- produced nonsense integrated_total
-- values of 0-100 instead of ~9-10M. Fixed with a two-stage aggregation: `monthly_stock` first
-- aggregates IS_INTEGRATED_TOTAL to real per-BP_MONTH totals, THEN `bridge` picks the LAST
-- month's already-correct total within each period via MAX_BY on that pre-aggregated value.
--
-- TEAM/MSP/REP BREAKOUT + MULTI-SELECT FILTERS + DUAL TIME COMPARISON, added 2026-08-05
-- (Debrief restructure, docs/superpowers/specs/2026-08-05-debrief-restructure-design.md) --
-- Parts B2 (Team), B3 (MSP), B4 (Rep) below are structural copies of Part B (Segment), same
-- CTE chain and bridge computation, only the partition key/CASE mapping changes. All 5 Parts
-- (A, B, B2, B3, B4) now accept the same Team/Segment/Msp/DealType/Rep multi-select IN (...)
-- filters and expose integrated_total_prior_period / integrated_total_trailing_avg_6period --
-- extends integrated_total, the metric each Part's own pre-existing net_change already trend-
-- tracks via LAG, not a new metric. Named "_6period" not "_6mo" since this file supports Month
-- OR Quarter via {{ Granularity.value }} (same rule niro_units_cube.sql's header documents).
--
-- POPULATION CONSISTENCY -- every breakout Part (B/B2/B3/B4) gates on the SAME
-- `segment_bucket IS NOT NULL` scope (the org-pod exclusion Part B already established --
-- DSMB 1-5/Partner Success/SDR-only/leadership pods and unmapped team names stay OUT of every
-- breakout, not just Segment's) so a coverage gap can't silently creep in depending on which
-- Part is queried -- same "POPULATION-CONSISTENCY BUG" class pipeline_cube.sql's header
-- documents and fixed live. Team is a NARROWER dimension on top of that shared gate -- House
-- Accounts and rows with no team mapping are excluded from Team specifically (no direct-report
-- manager owns them, same rule rolled_out_units_cube.sql's header already documents and Kevin
-- already approved) -- so Team's total is expected to run below Segment's total by exactly
-- House Accounts' volume, not a bug. MSP and Rep have no such narrowing: an unresolved MSP/Rep
-- is COALESCE'd to 'Not Set' rather than dropped, so their totals reconcile exactly against
-- Segment's total. RECONCILED LIVE -- see the commit message for this change for the actual
-- numbers.

-- Part A: company-wide bridge, trended, {{ LookbackMonths.value }} periods (default 8).
--
-- MULTI-SELECT FILTERS, added 2026-08-05 -- Team.value/Segment.value/Msp.value/
-- DealType.value/Rep.value are optional, pre-quoted comma-separated IN-lists (same convention
-- as every other cube in this repo). Filtering Part A narrows the COMPANY-WIDE bridge to a
-- subset (e.g. "just Strategic") without changing its shape -- still one trended row per
-- period, no breakout column added here. msp resolved via the same account-level
-- DIM_SALES_ACCOUNTS join niro_units_cube.sql already validated (HUBSPOT_COMPANY_ID =
-- ACCOUNT_SALESFORCE_ID, confirmed 1:1, no fan-out) -- property-level PMS isn't populated for
-- deactivated/non-integrated properties, same reasoning as every MSP cut in this repo.
--
-- DUAL TIME COMPARISON, added 2026-08-05 -- extends integrated_total, the metric this Part
-- already trend-tracks via `net_change`'s own pre-existing LAG below -- not a new metric.
-- integrated_total_prior_period exposes that same LAG value on its own (net_change already
-- subtracts it but never exposed the raw comparison), integrated_total_trailing_avg_6period is
-- a new trailing average (6 PRECEDING AND 1 PRECEDING, excluding the current row so it's an
-- independent baseline).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS msp
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
    WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT s.BP_MONTH, SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1
),
bridge AS (
    SELECT
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        MAX_BY(ms.integrated_total, s.BP_MONTH) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN monthly_stock ms ON s.BP_MONTH = ms.BP_MONTH
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1
)
SELECT
    period,
    integrated_total,
    integrated_total - LAG(integrated_total) OVER (ORDER BY period) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro,
    (integrated_total - LAG(integrated_total) OVER (ORDER BY period))
        - (new_integrated + deactivated + recaptured + uplevel_to_integrated + downlevel_to_niro) AS remaining_net_change,
    LAG(integrated_total) OVER (ORDER BY period) AS integrated_total_prior_period,
    AVG(integrated_total) OVER (ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS integrated_total_trailing_avg_6period
FROM bridge
QUALIFY period >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY period;

-- Part B: same bridge, by SEGMENT, all 4 segments scanned/returned at once (not filtered to
-- one at a time) -- lets the Debrief macro tier show "which segment is driving churn" without
-- a separate query per segment.
--
-- MULTI-SELECT FILTERS + DUAL TIME COMPARISON, added 2026-08-05 -- team_bucket/msp/
-- HUBSPOT_DEAL_TYPE/HUBSPOT_DEAL_OWNER now available in `scoped` alongside segment_bucket so
-- all 5 filters (Team/Segment/Msp/DealType/Rep) can layer together, same IN (...) convention
-- every other cube in this repo uses. integrated_total_prior_period/integrated_total_
-- trailing_avg_6period added to the final SELECT, partitioned by segment_bucket -- see the
-- header block above ("TEAM/MSP/REP BREAKOUT...") for the naming rationale, shared by every
-- Part in this file.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS msp
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
    WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT s.segment_bucket, s.BP_MONTH,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL
),
bridge AS (
    SELECT
        s.segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        MAX_BY(ms.integrated_total, s.BP_MONTH) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN monthly_stock ms ON s.BP_MONTH = ms.BP_MONTH AND s.segment_bucket = ms.segment_bucket
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1, 2
)
SELECT
    segment_bucket,
    period,
    integrated_total,
    integrated_total - LAG(integrated_total) OVER (PARTITION BY segment_bucket ORDER BY period) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro,
    LAG(integrated_total) OVER (PARTITION BY segment_bucket ORDER BY period) AS integrated_total_prior_period,
    AVG(integrated_total) OVER (PARTITION BY segment_bucket ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS integrated_total_trailing_avg_6period
FROM bridge
QUALIFY period >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY segment_bucket, period;

-- Part B2: same bridge, by TEAM (Brandon's/Sebastian's/Rory's/Dana's), all 4 teams scanned at
-- once -- added 2026-08-05 (Debrief restructure). Structural copy of Part B above, same CTE
-- chain and bridge computation, only the partition key changes (team_bucket instead of
-- segment_bucket) and the CASE mapping is the narrower team-grain mapping -- House Accounts
-- and rows with no team mapping are NOT valid Team values (no direct-report manager owns
-- them), same rule rolled_out_units_cube.sql's header already documents. Gated on the SAME
-- `segment_bucket IS NOT NULL` scope as Part B (see this file's top-of-file header) so the
-- in-scope population doesn't drift between breakouts -- team_bucket IS NOT NULL narrows it
-- further, on top of that shared gate, not instead of it.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS msp
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
    WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT s.team_bucket, s.BP_MONTH,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1, 2
    HAVING team_bucket IS NOT NULL
),
bridge AS (
    SELECT
        s.team_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        MAX_BY(ms.integrated_total, s.BP_MONTH) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN monthly_stock ms ON s.BP_MONTH = ms.BP_MONTH AND s.team_bucket = ms.team_bucket
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      AND s.team_bucket IS NOT NULL
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1, 2
)
SELECT
    team_bucket,
    period,
    integrated_total,
    integrated_total - LAG(integrated_total) OVER (PARTITION BY team_bucket ORDER BY period) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro,
    LAG(integrated_total) OVER (PARTITION BY team_bucket ORDER BY period) AS integrated_total_prior_period,
    AVG(integrated_total) OVER (PARTITION BY team_bucket ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS integrated_total_trailing_avg_6period
FROM bridge
QUALIFY period >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY team_bucket, period;

-- Part B3: same bridge, by MSP, all MSPs scanned at once -- added 2026-08-05 (Debrief
-- restructure). Structural copy of Part B, only the partition key changes -- MSP can't reuse
-- the HUBSPOT_STATIC_TEAM_NAME_DEAL-style mapping, resolved via the same account-level
-- DIM_SALES_ACCOUNTS join niro_units_cube.sql already validated (HUBSPOT_COMPANY_ID =
-- ACCOUNT_SALESFORCE_ID, confirmed 1:1, no fan-out) -- property-level PMS isn't populated for
-- deactivated/non-integrated properties, so it can't be used here (same reasoning as every
-- other MSP cut in this repo). Gated on the SAME segment_bucket IS NOT NULL population as
-- Part B/B2. Unlike Team, a missing/unresolved MSP is COALESCE'd to 'Not Set' rather than
-- excluded -- keeps the real "unknown MSP" volume visible instead of vanishing, and keeps this
-- breakout's total reconcilable against Part B's Segment total (RECONCILED LIVE -- see commit
-- message).
--
-- LARGE "NOT SET" BUCKET ON DEACTIVATIONS -- CONFIRMED LIVE, NOT A BUG. Checked live: ~39% of
-- deactivated units (38,932 of 98,840 for the period checked) have no resolvable MSP via this
-- join -- a real, expected data-coverage gap for churned accounts, not a bug (the reconciliation
-- above still ties out exactly, so this isn't a fan-out or dropped-row problem -- DIM_SALES_
-- ACCOUNTS simply doesn't reliably carry an MSP value once an account has churned). A large
-- 'Not Set' bucket on the deactivations cut specifically is normal -- don't mistake it for a
-- join failure.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        COALESCE(acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES, 'Not Set') AS msp
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
    WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT s.msp, s.BP_MONTH,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1, 2
),
bridge AS (
    SELECT
        s.msp,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        MAX_BY(ms.integrated_total, s.BP_MONTH) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN monthly_stock ms ON s.BP_MONTH = ms.BP_MONTH AND s.msp = ms.msp
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                 {{/Rep.value}}
    GROUP BY 1, 2
)
SELECT
    msp,
    period,
    integrated_total,
    integrated_total - LAG(integrated_total) OVER (PARTITION BY msp ORDER BY period) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro,
    LAG(integrated_total) OVER (PARTITION BY msp ORDER BY period) AS integrated_total_prior_period,
    AVG(integrated_total) OVER (PARTITION BY msp ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS integrated_total_trailing_avg_6period
FROM bridge
QUALIFY period >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY msp, period;

-- Part B4: same bridge, by REP (HUBSPOT_DEAL_OWNER), all reps scanned at once -- added
-- 2026-08-05 (Debrief restructure). Structural copy of Part B, partition key =
-- HUBSPOT_DEAL_OWNER, already the rep-name column every other file in this repo uses directly
-- (e.g. shout_outs_facts.sql). Gated on the same segment_bucket IS NOT NULL population as
-- every other Part above. A missing rep is COALESCE'd to 'Not Set' (same reasoning as MSP --
-- keep unresolved volume visible instead of dropping it). DEPARTED-REP GRACE PERIOD
-- DELIBERATELY NOT APPLIED HERE -- same reasoning as niro_units_cube.sql's header: this file's
-- deactivated/uplevel/downlevel columns are FLOW events tied to a specific historical
-- BP_MONTH, not a live stock total, so a departed rep's name against a real historical flow
-- event is useful information (who originally owned an account before it churned/uplevled/
-- downleveled), not noise.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS msp,
        COALESCE(s.HUBSPOT_DEAL_OWNER, 'Not Set') AS rep
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
    WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT s.rep, s.BP_MONTH,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.rep IN ({{Rep.value}})                                {{/Rep.value}}
    GROUP BY 1, 2
),
bridge AS (
    SELECT
        s.rep,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        MAX_BY(ms.integrated_total, s.BP_MONTH) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN monthly_stock ms ON s.BP_MONTH = ms.BP_MONTH AND s.rep = ms.rep
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      {{#Team.value}}      AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
      {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
      {{#Msp.value}}       AND s.msp IN ({{Msp.value}})                                {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
      {{#Rep.value}}       AND s.rep IN ({{Rep.value}})                                {{/Rep.value}}
    GROUP BY 1, 2
)
SELECT
    rep,
    period,
    integrated_total,
    integrated_total - LAG(integrated_total) OVER (PARTITION BY rep ORDER BY period) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro,
    LAG(integrated_total) OVER (PARTITION BY rep ORDER BY period) AS integrated_total_prior_period,
    AVG(integrated_total) OVER (PARTITION BY rep ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS integrated_total_trailing_avg_6period
FROM bridge
QUALIFY period >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY rep, period;

-- Part C: churn-acceleration streak scanner -- is DEACTIVATED magnitude growing for N
-- consecutive months, by segment, all segments scanned at once. Same gaps-and-islands
-- technique as insights_declining_streaks.sql, applied to |deactivated| instead of net
-- rollout units -- this is the proactive "churn is getting worse" flag, not just a number to
-- read off Part B.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND deactivated_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(deactivated_units - LAG(deactivated_units) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(deactivated_units, period) AS latest_deactivated_units
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, streak_len AS rising_churn_streak_months, latest_month, latest_deactivated_units
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY rising_churn_streak_months DESC;

-- Part D: single-month deactivation SPIKE flag, all segments scanned at once -- Kevin: "if
-- deactivations are way up this month probably something worth calling out too." Part C
-- above requires 2+ CONSECUTIVE months of rising churn to flag anything -- a real, sharp
-- one-month spike that hasn't (yet) repeated would be invisible to it. Same single-delta +
-- materiality-floor pattern as insights_trend_flags.sql, applied specifically to deactivated
-- units instead of general rolled-out volume (that file doesn't isolate deactivations at all).
-- Validated live: SMB deactivated units jumped 54% in one month (16,353 -> 25,186, Jul -> Aug)
-- -- a real, current spike Part C's streak requirement alone would not have caught yet.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -IFF('{{ Granularity.value }}' = 'Quarter', 6, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL
),
this_last AS (
    SELECT segment_bucket,
        MAX_BY(deactivated_units, period) AS deactivated_this,
        MAX_BY(IFF(period < (SELECT MAX(period) FROM monthly), deactivated_units, NULL), IFF(period < (SELECT MAX(period) FROM monthly), period, NULL)) AS deactivated_last
    FROM monthly
    GROUP BY segment_bucket
)
SELECT segment_bucket, deactivated_this, deactivated_last,
    DIV0(deactivated_this - deactivated_last, deactivated_last) AS pct_change
FROM this_last
WHERE deactivated_last >= {{ MinUnitsFloor.value }}
  AND DIV0(deactivated_this - deactivated_last, deactivated_last) >= {{ MinPctSpikeThreshold.value }}
ORDER BY pct_change DESC;
