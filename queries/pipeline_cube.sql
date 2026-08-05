-- Pipeline Cube -- consolidates pipeline_forecast.sql (open pipeline + closed-awaiting-
-- rollout), new_opportunities_by_msp.sql (MSP cut), and insights_forward_pipeline_trend.sql
-- (segment cut, as-of cohort technique) into ONE {{ Dimension.value }}-driven cube, same
-- one-query-drives-every-slice pattern as rolled_out_units_cube.sql/niro_units_cube.sql/
-- closed_lost_rate_cube.sql. Built for the Debrief restructure (see
-- docs/superpowers/specs/2026-08-05-debrief-restructure-design.md) -- Box 2's "Pipeline"
-- Subject needs one query that can break out by Segment, Team, MSP, or Rep -- the 3 files this
-- replaces only ever covered one dimension each.
--
-- INHERITS VALIDATED LOGIC, DOESN'T RE-DERIVE IT:
--   - Open pipeline (unweighted face value, ANTICIPATED_GO_LIVE_AT_UTC) + closed-awaiting-
--     rollout (ROLLOUT_MONTH, 88% historical accuracy) shown as separate components, same
--     confidence-gradient framing pipeline_forecast.sql's header already established --
--     narration must keep these visually distinct, never blend into one undifferentiated bar.
--   - New Vertical excluded (OPPORTUNITY_TYPE != 'New Vertical').
--   - DSMB excluded (pmc_size > 750 units, current-month IS_IN_NETWORK).
--   - 5-year sanity ceiling on top of {{ LookaheadMonths.value }} (defensive backstop, see
--     pipeline_forecast.sql's "2926-07" typo incident).
--   - MSP resolved via account-level DIM_SALES_ACCOUNTS join (same as niro_units_cube.sql --
--     PMS on PROPERTY_BP_MONTH_STATS is populated only on already-integrated properties, not
--     open pipeline, so the property-level column can't be used here at all).
--
-- JOIN KEY BUG CAUGHT LIVE 2026-08-05 -- the original draft joined
-- DIM_SALES_ACCOUNTS.ACCOUNT_SALESFORCE_ID to DIM_CRM_ACCOUNT_HISTORY.ACCOUNT_SALESFORCE_ID,
-- a column that doesn't exist on that table (confirmed via DESCRIBE TABLE -- FLEX.SALES.
-- DIM_CRM_ACCOUNT_HISTORY has ACCOUNT_ID, not ACCOUNT_SALESFORCE_ID). Fixed to join on
-- a.ACCOUNT_ID = am.ACCOUNT_SALESFORCE_ID -- confirmed live these are the same real Salesforce
-- account ID (sample rows match 1:1 on the '001...' Salesforce ID format) and that
-- DIM_SALES_ACCOUNTS.ACCOUNT_SALESFORCE_ID has zero duplicate non-NULL values (62,759 non-null
-- rows, 62,759 distinct values) -- no fan-out risk, same "confirmed 1:1" finding
-- niro_units_cube.sql already documented for this same table on its own join path.
--
-- MULTI-SELECT FILTERS -- {{ Team.value }}/{{ Segment.value }}/{{ Msp.value }}/
-- {{ DealType.value }}/{{ Rep.value }} are comma-separated, pre-quoted literal lists built by
-- Superblocks multi-select components (empty = no filter on that dimension), substituted
-- directly into IN (...) via plain Mustache literal substitution -- same convention every other
-- cube file in this repo uses, NOT STRTOK_TO_ARRAY (no Snowflake array-splitting happens in this
-- file). A single selected value behaves identically to today's single-value dropdown filters.
--
-- MISSING FILTER CAUGHT LIVE 2026-08-05 -- this header already claimed DealType.value as a
-- supported filter, but the first committed draft never actually selected OPPORTUNITY_TYPE in
-- either `open_pipeline`/`closed_awaiting_rollout`, so the filter silently did nothing (Task 9's
-- Superblocks wiring doc assumes every cube supports it). Fixed: added `deal_type` to both CTEs
-- and a `{{#DealType.value}} AND c.deal_type IN (...) {{/DealType.value}}` block in `filtered`.
-- deal_type is filter-only here, never a breakout {{ Dimension.value }} option, so it's
-- deliberately absent from `periods`' GROUP BY -- see that CTE's own comment for why adding it
-- there would change nothing anyway.
--
-- DEPARTED-REP GRACE PERIOD -- {{ GraceMonths.value }} (default 2, same as every other cube in
-- this repo) keeps a departed rep's Rep-dimension rows visible for that many months past their
-- last login before dropping them, instead of vanishing the day IS_ACTIVE flips to FALSE. See
-- the inline comment on `filtered`'s WHERE clause for the exact condition and scoping.
--
-- DUAL TIME COMPARISON -- {{ TargetPeriod.value }} is the period Sham is inspecting (a BP
-- month or quarter). `prior_period_value` = the immediately preceding period of the same
-- grain. `trailing_avg_value` = trailing-4-quarters average if Granularity=Quarter, trailing-
-- 6-months if Granularity=Month, trailing-4-weeks if Granularity=Week (weeks not natively
-- supported by BP_MONTH grain -- Week granularity on this file falls back to Month, documented
-- limitation, revisit if Sham actually needs week-level pipeline).

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
user_dedup AS (
    SELECT FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
current_rep AS (
    SELECT FULL_NAME,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
            WHEN TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            WHEN TEAM_NAME IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM user_dedup
),
acct_msp AS (
    -- Account-level MSP, same join niro_units_cube.sql already validated -- confirmed 1:1,
    -- no fan-out risk.
    SELECT ACCOUNT_SALESFORCE_ID, ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS msp
    FROM PRODUCTION.SALES.DIM_SALES_ACCOUNTS
),
open_pipeline AS (
    SELECT
        o.OPPORTUNITY_ID,
        DATE_TRUNC('month', o.ANTICIPATED_GO_LIVE_AT_UTC) AS expected_month,
        cr.segment_bucket, cr.team_bucket,
        am.msp,
        e.FULL_NAME AS rep,
        cr.IS_ACTIVE, cr.LAST_LOGIN_AT_UTC,
        o.OPPORTUNITY_TYPE AS deal_type,
        o.FLEX_UNIT_COUNT AS units,
        'open_pipeline' AS component
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    LEFT JOIN current_rep cr ON cr.FULL_NAME = e.FULL_NAME
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    LEFT JOIN acct_msp am ON am.ACCOUNT_SALESFORCE_ID = a.ACCOUNT_ID
    WHERE NOT o.IS_CLOSED
      AND o.OPPORTUNITY_TYPE != 'New Vertical'
      AND o.ANTICIPATED_GO_LIVE_AT_UTC >= CURRENT_DATE()
      AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(month, {{ LookaheadMonths.value }}, CURRENT_DATE())
      AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
),
closed_awaiting_rollout AS (
    SELECT
        li.LINE_ITEM_ID AS OPPORTUNITY_ID,
        DATE_TRUNC('month', li.ROLLOUT_MONTH) AS expected_month,
        cr.segment_bucket, cr.team_bucket,
        am.msp,
        e.FULL_NAME AS rep,
        cr.IS_ACTIVE, cr.LAST_LOGIN_AT_UTC,
        o.OPPORTUNITY_TYPE AS deal_type,
        li.UNIT_COUNT AS units,
        'closed_awaiting_rollout' AS component
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    LEFT JOIN current_rep cr ON cr.FULL_NAME = e.FULL_NAME
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    LEFT JOIN acct_msp am ON am.ACCOUNT_SALESFORCE_ID = a.ACCOUNT_ID
    WHERE o.IS_CLOSED_WON
      AND o.OPPORTUNITY_TYPE != 'New Vertical'
      AND li.ROLLOUT_MONTH > CURRENT_DATE()
      AND li.ROLLOUT_MONTH <= DATEADD(month, {{ LookaheadMonths.value }}, CURRENT_DATE())
      AND li.ROLLOUT_MONTH <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
),
combined AS (
    SELECT * FROM open_pipeline
    UNION ALL
    SELECT * FROM closed_awaiting_rollout
),
filtered AS (
    SELECT c.*,
        COALESCE({{ Dimension.value }}, 'Not Set') AS entity
    FROM combined c
    -- CASE-DISPATCH BUG CAUGHT LIVE 2026-08-05 (predates and is more severe than the population-
    -- consistency bug documented below) -- {{ Dimension.value }} renders as a BARE, UNQUOTED
    -- column identifier in this repo's convention (confirmed by every sibling cube --
    -- niro_units_cube.sql/rolled_out_units_cube.sql/closed_lost_rate_cube.sql all write
    -- `COALESCE({{ Dimension.value }}, 'Not Set')` directly, no CASE wrapper -- and by this
    -- file's own grace-period filter below, which correctly wraps it in literal quotes
    -- `'{{ Dimension.value }}' = 'rep'` specifically BECAUSE the raw substitution has no quotes
    -- of its own). The original draft instead wrote `CASE {{ Dimension.value }} WHEN
    -- 'segment_bucket' THEN c.segment_bucket ...`, which renders as e.g. `CASE rep WHEN
    -- 'segment_bucket' THEN ...` -- testing each row's rep NAME against the literal string
    -- 'segment_bucket', which can never match. Confirmed live: every Dimension value (segment_
    -- bucket/team_bucket/msp/rep) returned a single `entity = 'Not Set'` bucket for 100% of rows
    -- -- the CASE always fell through to the implicit ELSE (NULL), COALESCE'd to 'Not Set'. This
    -- silently passed both rounds of live validation so far because every check run compared
    -- SUM(units) totals across dimensions, which stay correct regardless of whether `entity` is
    -- labeled right -- the rows were still being grouped on the SAME real underlying columns via
    -- GROUP BY entity, just all lumped under one wrong label instead of split apart. Fixed: bare
    -- substitution, identical to every sibling cube -- `{{ Dimension.value }}` resolves directly
    -- to whichever real column (segment_bucket/team_bucket/msp/rep) Superblocks binds, no CASE/
    -- dispatch layer needed since those columns already exist under their real names on `c.*`.
    --
    -- POPULATION-CONSISTENCY BUG CAUGHT LIVE 2026-08-05 -- the original draft gated the whole
    -- query on `entity IS NOT NULL` (below, in `periods`), meaning the in-scope POPULATION
    -- silently changed depending on which {{ Dimension.value }} was selected: rows from
    -- excluded org pods (DSMB 1-5, GTM Support Teams, SMB Manager, SDR-only pods -- same
    -- exclusion list rolled_out_units_cube.sql/niro_units_cube.sql already apply) have NULL
    -- segment_bucket/team_bucket by design, so they correctly dropped out of the Segment/Team
    -- views -- but if that same row's account happened to resolve to a real MSP or its owner
    -- resolved to a real rep name, it leaked straight through into the MSP/Rep views instead of
    -- being excluded there too. Confirmed live: Sep 2026 open-pipeline segment_bucket total =
    -- 802,755 units, but the msp total for the SAME month = 969,408 units -- ~166K too high,
    -- matching almost exactly the ~165,601 units sitting in excluded pods (DSMB 1-5, GTM Support
    -- Teams, SMB Manager, SDR pods) for that same window. Not a join fan-out (DIM_SALES_ACCOUNTS.
    -- ACCOUNT_SALESFORCE_ID has zero duplicate non-NULL values, confirmed live) -- the real cause
    -- was `entity IS NOT NULL` silently acting as a per-dimension scope filter instead of a fixed,
    -- dimension-independent one. Fixed: scope is now gated ONCE on `segment_bucket IS NOT NULL`
    -- (below), the same population no matter which Dimension is displayed, and `entity` itself is
    -- COALESCE'd to 'Not Set' so a real MSP/Rep coverage gap on an IN-SCOPE row stays visible as
    -- its own bucket instead of vanishing (same COALESCE(..., 'Not Set') convention every other
    -- cube file in this repo already uses for its dimension column).
    WHERE c.segment_bucket IS NOT NULL
      {{#Team.value}}     AND c.team_bucket    IN ({{Team.value}})     {{/Team.value}}
      {{#Segment.value}}  AND c.segment_bucket IN ({{Segment.value}})  {{/Segment.value}}
      {{#Msp.value}}      AND c.msp            IN ({{Msp.value}})      {{/Msp.value}}
      {{#DealType.value}} AND c.deal_type      IN ({{DealType.value}}) {{/DealType.value}}
      {{#Rep.value}}      AND c.rep            IN ({{Rep.value}})      {{/Rep.value}}
      -- DEPARTED-REP GRACE PERIOD, SCOPED TO THE REP DIMENSION ONLY -- caught in code review
      -- 2026-08-05: `current_rep` already selected IS_ACTIVE/LAST_LOGIN_AT_UTC but nothing ever
      -- read them, so a departed rep's open pipeline/closed-awaiting-rollout units could show up
      -- under the Rep breakout with no grace period at all. Same pattern closed_lost_rate_cube.
      -- sql already applies, scoped the same way (departed-rep filter bites ONLY when Dimension=
      -- 'rep' -- applying it unconditionally would corrupt Segment/Team/MSP totals, same lesson
      -- niro_units_cube.sql's header already documents for stock aggregates).
      AND (NOT ('{{ Dimension.value }}' = 'rep') OR c.IS_ACTIVE OR c.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
),
periods AS (
    -- deal_type is filter-only, never a breakout dimension (Dimension.value only ever resolves
    -- to segment_bucket/team_bucket/msp/rep, see `filtered` above) -- deliberately NOT added to
    -- this GROUP BY. Confirmed live it wouldn't change anything even if added: this CTE already
    -- only selects expected_month/entity/component from `filtered`, so a row's deal_type is
    -- aggregated away by the SUM(units) regardless -- adding it here would just re-explode rows
    -- back out by deal type underneath every entity, which is not what any Dimension option asks
    -- for. If a future Subject ever needs a deal-type breakout, that's a new {{ Dimension.value }}
    -- branch in `filtered`, not a change to this GROUP BY.
    SELECT expected_month, entity, component,
        SUM(units) AS units
    FROM filtered
    GROUP BY 1, 2, 3
)
SELECT
    entity,
    component,
    expected_month,
    units,
    -- Dual time comparison, against the SAME expected_month across a trailing window of
    -- "as-of-today" snapshots isn't meaningful for forward pipeline (it only exists looking
    -- forward from today) -- so for THIS cube, prior_period/trailing_avg compare the pipeline
    -- currently on the books for expected_month vs. the month immediately before it and the
    -- trailing 6 months before it, i.e. "is the pipeline further out shaped differently than
    -- the pipeline right in front of us" -- not a historical replay (this cube shows current,
    -- forward-looking state only -- insights_forward_pipeline_trend.sql already owns the as-of-
    -- N-days-ago historical reconstruction, this file does not duplicate that).
    LAG(units) OVER (PARTITION BY entity, component ORDER BY expected_month) AS prior_period_units,
    AVG(units) OVER (PARTITION BY entity, component ORDER BY expected_month ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS trailing_avg_units
FROM periods
ORDER BY entity, component, expected_month;
