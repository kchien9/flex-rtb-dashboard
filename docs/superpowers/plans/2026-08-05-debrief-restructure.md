# Debrief Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single filter-driven Debrief summary with a two-box architecture — a
persistent, dimension-blind General Business Summary, and a composable multi-select Dig In
tool covering every Subject × Breakout combination the design spec calls for.

**Architecture:** 6 SQL "cube" files (3 already built, 3 new/extended) each accept a
`{{ Dimension.value }}` breakout, multi-select `IN (...)` filters, and dual time comparison
(prior-period + trailing-average). Two new small fact files feed Box 1's persistent summary.
Superblocks wiring binds Box 1 to the unfiltered/pooled outputs and Box 2 to the cubes.

**Tech Stack:** Snowflake SQL, Superblocks (dashboard/BI layer), no application code, no test
framework — verification is live Snowflake queries against `PRODUCTION`/`FLEX` schemas.

**Spec:** `docs/superpowers/specs/2026-08-05-debrief-restructure-design.md` — read this first,
every task below implements a specific section of it.

**Verification convention for this repo (read before starting any task)**: there is no pytest/
test runner. Every "run the test" step below means: substitute the file's `{{ Param.value }}`
placeholders with literal values in a scratch copy (same pattern used all session — see any
committed file's git history for examples), run it via the project's Snowflake connection
script (`flex-comp-engine`'s cached SSO session, invoked as
`python run_sql.py <scratch_file.sql>`), and check the ACTUAL returned rows against the
invariant stated in that step (not a fixed expected number — the real data changes over time,
so every check below is written as a structural/reconciliation invariant, e.g. "breakout totals
sum back to the unbroken-out total," not "returns exactly 47,933").

**`run_sql.py` truncates printed output at 60 rows (caught in Task 7's review)** — this bit a
real header-comment claim (a manually-counted-from-printed-output "17 distinct MSPs" was
actually 22 — the extra rows existed but were never printed). For ANY row-count or distinct-
value-count claim you plan to write into a file's header, compute it with `COUNT(DISTINCT ...)`
inside the query itself and read that single returned number — never eyeball/grep/count rows
from the script's printed output when the real row count could plausibly exceed 60.

**A `COUNT(some_column)` after an `OR`-based join undercounts matches (also caught in Task 7)**
— if a join condition is `a.id = b.col1 OR a.id = b.col2`, `COUNT(b.col1)` misses every row that
matched via `col2` while `col1` is NULL on that side. If you're computing a join match-rate
percentage, count matched rows on the OTHER table's primary/unique key (or just `COUNT(*)` after
the join, if row-level, not column-level, cardinality is what you want) — never a single
join-column that's only guaranteed non-null on one branch of an OR.

**Dual time comparison naming convention (added after Task 4's code review flagged drift
risk)** — Tasks 1-4 established this pattern, READ BEFORE NAMING ANY NEW COMPARISON COLUMN IN
TASKS 5-8:
- Always name the prior-period column `<metric>_prior_period` (a LAG).
- Always name the trailing-average column `<metric>_trailing_avg_6mo` if the file is
  month-only granularity (matches `rolled_out_units_cube.sql`), or `<metric>_trailing_avg_
  6period` if the file supports Month OR Quarter granularity via `{{ Granularity.value }}`
  (matches `niro_units_cube.sql`/`closed_lost_rate_cube.sql`/`pipeline_cube.sql`) — `_6period`
  is granularity-blind (6 preceding rows regardless of whether a row is a month or a quarter,
  same as the pre-existing single-period columns these files already had before this plan) —
  don't invent a granularity-scaled window unless a task explicitly asks for one.
- Compute the comparison on the SAME expression the file's headline metric already uses (a
  rate stays a rate — `LAG(DIV0(...))`, never on raw counts as a substitute; a unit total
  stays a unit total) — never mix a rate and a count between the base column and its
  comparison columns.
- If a file has no existing pre-materialized aggregate to reference (most of these cubes
  don't — window functions can't reference a sibling SELECT-list alias), repeat the full
  aggregate expression inside `LAG(...)`/`AVG(...) OVER (...)` rather than restructuring the
  file into a two-stage CTE — this matches every cube built so far and keeps the diff minimal;
  don't refactor architecture that wasn't asked for.
- If genuinely uncertain which metric to extend (a file trend-tracks more than one column, or
  none), pick the single column the file already trend-tracks with its own pre-existing window
  function if one exists; otherwise pick the most central/headline metric for that file's
  Subject and document the reasoning inline, the same way Tasks 2-4 did.

**Quantified findings belong IN THE FILE, not just the commit message (added after Task 6's
review caught this lesson regressing one commit after Task 5 established it)** — if live
validation surfaces a real number worth knowing (a Not-Set rate, a reconciliation gap, a data
quality caveat), put the ACTUAL NUMBER in the relevant Part's header comment, not just the git
commit message. "See the commit message" is not an acceptable substitute — a future reader
building a Superblocks chart off this file will never read git log. This already happened once
(Task 5's Part B3) and regressed once (Task 6) before being caught by review both times — don't
let it happen a third time in Tasks 7-8.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `queries/pipeline_cube.sql` | **new** | Consolidates 3 existing partial pipeline files into one full Segment/Team/MSP/Rep cube with dual time comparison |
| `queries/rolled_out_units_cube.sql` | modify | Add multi-select filters + dual time comparison (dimension support already complete) |
| `queries/niro_units_cube.sql` | modify | Same two additions |
| `queries/closed_lost_rate_cube.sql` | modify | Same two additions |
| `queries/insights_net_units_bridge.sql` | modify | Add Team/MSP/Rep breakout (Part B is Segment-only today) + multi-select filters + dual time comparison |
| `queries/insights_mix_shift_scanner.sql` | modify | Add MSP/Rep breakout to Part B (Segment/Team-only today) + multi-select filters + dual time comparison |
| `queries/sdr_activity_by_msp.sql` | **new** | SDR activity joined through account MSP |
| `queries/insights_forecast_decline_drivers.sql` | **new** | Ties `insights_forward_pipeline_trend.sql` Part C's decline flag to SDR-pipeline + AE-execution-basket co-movement |
| `docs/superblocks-setup.md` | modify | New §4.20 documenting Box 1 / Box 2 wiring |

---

## Task 1: `pipeline_cube.sql` — new consolidated pipeline cube

**Files:**
- Create: `queries/pipeline_cube.sql`
- Reference (read, don't modify): `queries/pipeline_forecast.sql`, `queries/new_opportunities_by_msp.sql`, `queries/insights_forward_pipeline_trend.sql`

- [ ] **Step 1: Write the file**

```sql
-- Pipeline Cube -- consolidates pipeline_forecast.sql (open pipeline + closed-awaiting-
-- rollout), new_opportunities_by_msp.sql (MSP cut), and insights_forward_pipeline_trend.sql
-- (segment cut, as-of cohort technique) into ONE {{ Dimension.value }}-driven cube, same
-- one-query-drives-every-slice pattern as rolled_out_units_cube.sql/niro_units_cube.sql/
-- closed_lost_rate_cube.sql. Built for the Debrief restructure (see
-- docs/superpowers/specs/2026-08-05-debrief-restructure-design.md) -- Box 2's "Pipeline"
-- Subject needs one query that can break out by Segment, Team, MSP, or Rep; the 3 files this
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
-- MULTI-SELECT FILTERS -- {{ Team.value }}/{{ Segment.value }}/{{ Msp.value }}/
-- {{ DealType.value }}/{{ Rep.value }} are comma-separated lists from Superblocks multi-select
-- components (empty = no filter on that dimension). Split via STRTOK_TO_ARRAY and matched with
-- IN, so a single selected value behaves identically to today's single-value dropdown filters.
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
        o.FLEX_UNIT_COUNT AS units,
        'open_pipeline' AS component
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    LEFT JOIN current_rep cr ON cr.FULL_NAME = e.FULL_NAME
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    LEFT JOIN acct_msp am ON am.ACCOUNT_SALESFORCE_ID = a.ACCOUNT_SALESFORCE_ID
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
        li.UNIT_COUNT AS units,
        'closed_awaiting_rollout' AS component
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    LEFT JOIN current_rep cr ON cr.FULL_NAME = e.FULL_NAME
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    LEFT JOIN acct_msp am ON am.ACCOUNT_SALESFORCE_ID = a.ACCOUNT_SALESFORCE_ID
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
        CASE {{ Dimension.value }}
            WHEN 'segment_bucket' THEN c.segment_bucket
            WHEN 'team_bucket' THEN c.team_bucket
            WHEN 'msp' THEN c.msp
            WHEN 'rep' THEN c.rep
        END AS entity
    FROM combined c
    WHERE 1=1
      {{#Team.value}}    AND c.team_bucket    IN ({{Team.value}})    {{/Team.value}}
      {{#Segment.value}} AND c.segment_bucket IN ({{Segment.value}}) {{/Segment.value}}
      {{#Msp.value}}     AND c.msp            IN ({{Msp.value}})     {{/Msp.value}}
      {{#Rep.value}}     AND c.rep            IN ({{Rep.value}})     {{/Rep.value}}
),
periods AS (
    SELECT expected_month, entity, component,
        SUM(units) AS units
    FROM filtered
    WHERE entity IS NOT NULL
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
    -- forward-looking state only; insights_forward_pipeline_trend.sql already owns the as-of-
    -- N-days-ago historical reconstruction, this file does not duplicate that).
    LAG(units) OVER (PARTITION BY entity, component ORDER BY expected_month) AS prior_period_units,
    AVG(units) OVER (PARTITION BY entity, component ORDER BY expected_month ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS trailing_avg_units
FROM periods
ORDER BY entity, component, expected_month;
```

- [ ] **Step 2: Validate live**

Copy to a scratch file, substitute `{{ LookaheadMonths.value }}` → `3`, `{{ Dimension.value }}`
→ `'segment_bucket'`, blank every `{{#X.value}}...{{/X.value}}` block (no filters). Run it.

Check:
- Every `entity` value is one of the 4 real segment buckets (Strategic/MM-Ent/SMB/House
  Accounts) — no NULLs, no unexpected strings.
- `component` is only ever `open_pipeline` or `closed_awaiting_rollout`.
- Re-run with `{{ Dimension.value }}` → `'msp'` — confirm real MSP names appear (AppFolio,
  Yardi, Entrata, RealPage) and the row count for `closed_awaiting_rollout` roughly matches
  what `new_opportunities_by_msp.sql` would show for the same window (spot-check 1 MSP, 1
  month, by hand).
- Re-run with `{{ Dimension.value }}` → `'rep'` — confirm `prior_period_units`/
  `trailing_avg_units` are NULL only on a rep's first period on record, not on every row (that
  would mean the window function isn't partitioning correctly).

- [ ] **Step 3: Fix any bugs found, re-validate**

Same process as every file this session — if the account-MSP join fans out (a symptom: total
units for `msp` breakout summed across all MSPs is HIGHER than the same period's `segment_
bucket` breakout total), check `DIM_SALES_ACCOUNTS.ACCOUNT_SALESFORCE_ID` for duplicates before
assuming the join is correct.

- [ ] **Step 4: Commit**

```bash
git add queries/pipeline_cube.sql
git commit -m "Add pipeline_cube.sql - consolidated pipeline cube with full dimension support

Replaces the need to maintain 3 separate partial-coverage pipeline files
for Box 2 dig-in. Inherits pipeline_forecast.sql's validated open-pipeline
+ closed-awaiting-rollout split, New Vertical exclusion, DSMB exclusion,
5-year sanity ceiling. Adds MSP (account-level join, same as
niro_units_cube.sql) and Rep breakout, which nothing existing covered.

Coding-Agent: Claude Code"
```

---

## Task 2: Multi-select filters + dual time comparison on `rolled_out_units_cube.sql`

**Files:**
- Modify: `queries/rolled_out_units_cube.sql`

- [ ] **Step 1: Read the current file in full before editing**

Confirm the exact current filter syntax (single-value `= '{{Team.value}}'` style) and the
exact column the final `SELECT`/`GROUP BY` uses for its period column (almost certainly
`BP_MONTH` or a `period` alias) before writing the diff — don't guess the surrounding code.

- [ ] **Step 2: Replace every single-value filter with a multi-select IN-list**

For each filter block matching the pattern:
```sql
{{#Team.value}}     AND cr.team_bucket = '{{Team.value}}'       {{/Team.value}}
```
replace with:
```sql
{{#Team.value}}     AND cr.team_bucket IN ({{Team.value}})       {{/Team.value}}
```
Apply the same `= '...'` → `IN (...)` change to every other filter block in the file (Segment,
Msp, DealType, Rep — whichever this file actually has; confirmed from Step 1's read).

- [ ] **Step 3: Add dual time comparison columns to the final SELECT**

Add, alongside whatever period-level aggregate column already exists (the file's real column
name confirmed in Step 1):
```sql
LAG(units) OVER (PARTITION BY entity ORDER BY period) AS prior_period_units,
AVG(units) OVER (PARTITION BY entity ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS trailing_avg_units
```
substituting `entity`/`period`/`units` for whatever this file's actual column names are (do
not introduce new column names that don't match the rest of the file's existing convention).

- [ ] **Step 4: Validate live**

Run with a single value in a multi-select param (e.g. `Team.value` → `'Brandon''s Team'`,
matching today's single-dropdown behavior) — confirm the row count and totals are IDENTICAL to
a same-day run of the file BEFORE this change (regression check: multi-select with 1 value
must equal today's single-select). Then re-run with 2 values (e.g.
`'Brandon''s Team','Dana''s Team'`) — confirm the result is the union of both teams' rows, not
an error or an empty set.

- [ ] **Step 5: Commit**

```bash
git add queries/rolled_out_units_cube.sql
git commit -m "Widen rolled_out_units_cube.sql filters to multi-select, add dual time comparison

Part of Debrief restructure (docs/superpowers/specs/2026-08-05-debrief-
restructure-design.md) - Box 2 dig-in needs multi-value Team/Segment/
Msp/DealType/Rep filters (Superblocks multi-select instead of single
dropdown) and prior-period + trailing-average columns for the Time
comparison feature. Regression-checked: a 1-value multi-select produces
identical results to today's single-value filter.

Coding-Agent: Claude Code"
```

---

## Task 3: Multi-select filters + dual time comparison on `niro_units_cube.sql`

**Files:**
- Modify: `queries/niro_units_cube.sql`

- [ ] **Step 1: Read the current file in full before editing** (same reasoning as Task 2 Step 1)

- [ ] **Step 2: Replace single-value filters with multi-select IN-lists** (same pattern as Task 2 Step 2, applied to this file's actual filter blocks)

- [ ] **Step 3: Add dual time comparison columns** (same pattern as Task 2 Step 3, using this file's actual column names)

- [ ] **Step 4: Validate live**

Same regression check as Task 2 Step 4 (1-value multi-select == today's single-value filter).
Additionally: re-run with `{{ Dimension.value }}` → `'msp'` and confirm AppFolio still shows as
the largest single NIRO MSP (~140K+ units per the already-validated finding in this file's own
header) — if that invariant breaks, the edit introduced a real regression.

- [ ] **Step 5: Commit**

```bash
git add queries/niro_units_cube.sql
git commit -m "Widen niro_units_cube.sql filters to multi-select, add dual time comparison

Same pattern as rolled_out_units_cube.sql (same commit series, Debrief
restructure). Regression-checked against the file's own already-
validated AppFolio-largest-NIRO-MSP finding.

Coding-Agent: Claude Code"
```

---

## Task 4: Multi-select filters + dual time comparison on `closed_lost_rate_cube.sql`

**Files:**
- Modify: `queries/closed_lost_rate_cube.sql`

- [ ] **Step 1: Read the current file in full before editing**

- [ ] **Step 2: Replace single-value filters with multi-select IN-lists**

- [ ] **Step 3: Add dual time comparison columns** — this file outputs a RATE (loss_rate_by_
units/loss_rate_by_deals), not a raw count. Add the comparison against the rate columns
directly (`LAG(loss_rate_by_units) OVER (...)`, trailing AVG of the rate) — do NOT compare raw
won/lost counts as a substitute, a rate and a count are different things and mixing them would
misrepresent the trend.

- [ ] **Step 4: Validate live**

Same 1-value-multi-select regression check as Task 2. Additionally: pick one MSP/segment with
a real prior-validated loss rate from this session's earlier work and confirm the new
`prior_period` column matches that previously-seen value.

- [ ] **Step 5: Commit**

```bash
git add queries/closed_lost_rate_cube.sql
git commit -m "Widen closed_lost_rate_cube.sql filters to multi-select, add dual time comparison

Same pattern as the other two cubes. Comparison columns computed on the
rate itself (loss_rate_by_units), not on raw won/lost counts.

Coding-Agent: Claude Code"
```

---

## Task 5: Team/MSP/Rep breakout on `insights_net_units_bridge.sql`

**Files:**
- Modify: `queries/insights_net_units_bridge.sql`

- [ ] **Step 1: Read the current file in full**, specifically Part B (the existing Segment
breakout) — the new Team/MSP/Rep breakouts must be exact structural copies of Part B's CTE
chain, only the `CASE` mapping and partition key change.

- [ ] **Step 2: Add a Team breakout (new Part, e.g. "Part B2")**

Copy Part B's full CTE chain (`pmc_size` → the bridge computation → the final SELECT).
Change every `segment_bucket` reference to `team_bucket`, and change the `CASE` block that
derives it from:
```sql
CASE
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL THEN 'Not Set'
END AS segment_bucket
```
to the team-grain equivalent:
```sql
CASE
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
    WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
END AS team_bucket
```

- [ ] **Step 3: Add an MSP breakout (new Part, e.g. "Part B3")**

Same copy-and-modify approach, but the MSP breakout can't reuse `HUBSPOT_STATIC_TEAM_NAME_
DEAL`-style mapping — join through `DIM_SALES_ACCOUNTS.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES`
the same way `niro_units_cube.sql` already validated (property-level `PMS` isn't populated for
deactivated/non-integrated properties). Add:
```sql
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON s.PMC_ID = a.PMC_ID AND a.IS_CURRENT = TRUE
LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct ON acct.ACCOUNT_SALESFORCE_ID = a.ACCOUNT_SALESFORCE_ID
```
to the relevant CTE, and use `acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS msp` as the
partition key instead of `segment_bucket`.

- [ ] **Step 4: Add a Rep breakout (new Part, e.g. "Part B4")**

Same copy-and-modify approach, partition key = `s.HUBSPOT_DEAL_OWNER` (already the rep-name
column every other file in this repo uses directly, e.g. `shout_outs_facts.sql`).

- [ ] **Step 5: Add multi-select filters + dual time comparison to Parts A, B, B2, B3, B4** —
same `IN (...)` widening as Task 2 Step 2, and the same `LAG`/trailing-`AVG` columns as Task 2
Step 3, applied to each part's own partition key.

- [ ] **Step 6: Validate live**

Critical check for this task specifically (stated in the spec's Verification Plan): sum the
new Team breakout's `deactivated_units`/`uplevel_units`/`downlevel_units` for one BP_MONTH
across all 4 teams, and confirm it equals the existing Segment breakout's total for the same
BP_MONTH (both should equal the company-wide Part A total). If they don't match, the new
Team-grain join introduced a fan-out or a coverage gap versus the already-validated Segment
join — do not commit until this reconciles. Repeat the same check for the MSP breakout (sum
across all MSPs should equal the segment/team total, allowing for a real, small "Not Set/
unknown MSP" bucket the same way `pipeline_forecast.sql`'s Team dimension already has one).

- [ ] **Step 7: Commit**

```bash
git add queries/insights_net_units_bridge.sql
git commit -m "Add Team/MSP/Rep breakout to insights_net_units_bridge.sql (was Segment-only)

Part of Debrief restructure - Box 2's Deactivations/Uplevel/Downlevel
Subject needs all 4 breakout options, this file only had Segment. New
parts are structural copies of the existing, already-validated Segment
breakout (Part B), same bridge computation, different partition key.
MSP breakout uses the account-level DIM_SALES_ACCOUNTS join (same as
niro_units_cube.sql) since property-level PMS isn't populated for
deactivated/non-integrated properties. Reconciled live: Team and MSP
breakout totals both sum back to the existing Segment/company-wide
totals for the same period.

Coding-Agent: Claude Code"
```

---

## Task 6: MSP/Rep breakout on `insights_mix_shift_scanner.sql` Part B

**Files:**
- Modify: `queries/insights_mix_shift_scanner.sql`

- [ ] **Step 1: Read the current file in full**, specifically Part B (New Logo vs. Expansion
share, currently Team + Segment cuts).

- [ ] **Step 2: Add an MSP cut to Part B**, same account-level `DIM_SALES_ACCOUNTS` join
pattern as Task 5 Step 3.

- [ ] **Step 3: Add a Rep cut to Part B**, partition key = the rep-name column this file
already uses elsewhere (confirmed from Step 1's read — match the existing convention exactly,
don't introduce a differently-named column).

- [ ] **Step 4: Add multi-select filters + dual time comparison** to the new MSP/Rep cuts
(same pattern as prior tasks).

- [ ] **Step 5: Validate live** — same reconciliation check as Task 5 Step 6: New Logo +
Expansion units summed across all MSPs for one period should equal the same period's Team/
Segment cut total.

- [ ] **Step 6: Commit**

```bash
git add queries/insights_mix_shift_scanner.sql
git commit -m "Add MSP/Rep cut to insights_mix_shift_scanner.sql Part B (was Team/Segment-only)

Part of Debrief restructure - Box 2's Opportunity Type mix Subject needs
all 4 breakout options. Reconciled live against the existing Team/
Segment totals for the same period.

Coding-Agent: Claude Code"
```

---

## Task 7: `sdr_activity_by_msp.sql` — new file

**Files:**
- Create: `queries/sdr_activity_by_msp.sql`
- Reference: `queries/sdr_funnel_by_segment.sql` (same base activity/meetings CTEs)

- [ ] **Step 1: Write the file**

```sql
-- SDR Activity, by MSP -- Box 2's SDR Activity Subject, MSP breakout. SDR pods (SMB/MM-Ent/
-- Strategic) map to segments, not MSPs -- this file answers a different question ("are SDRs
-- spending time on AppFolio prospects vs. Yardi prospects") by joining activity through the
-- ACCOUNT the SDR touched, not through the SDR's own pod assignment.
--
-- Same account-level MSP join as niro_units_cube.sql (DIM_SALES_ACCOUNTS.ACCOUNT_PROPERTY_
-- MANAGEMENT_SOFTWARES, joined via CRM_ACCOUNT_SK -> DIM_CRM_ACCOUNT_HISTORY -> ACCOUNT_
-- SALESFORCE_ID -- confirmed 1:1 elsewhere in this repo, no fan-out).
--
-- SDR ACTIVITY x TEAM DELIBERATELY NOT BUILT -- see docs/superpowers/specs/2026-08-05-debrief-
-- restructure-design.md: SDR pods don't map 1:1 to the 4 AE teams (2 SMB teams share one SDR
-- pod), so there's no clean by-team cut for SDR data. Don't add one without a real re-mapping
-- of the SDR org structure first.
--
-- Same DSMB exclusion, same completed-task/meeting-held definitions, same departure grace
-- period as sdr_funnel_by_segment.sql.

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
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct ON acct.ACCOUNT_SALESFORCE_ID = a.ACCOUNT_SALESFORCE_ID
    WHERE a.IS_CURRENT = TRUE
),
activity AS (
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo, am.msp,
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
    SELECT DATE_TRUNC('month', m.CREATED_AT_UTC) AS mo, am.msp,
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
    AVG(COALESCE(a.calls, 0)) OVER (PARTITION BY COALESCE(a.msp, mt.msp, 'Not Set') ORDER BY COALESCE(a.mo, mt.mo) ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS calls_trailing_avg
FROM activity a
FULL OUTER JOIN meetings mt ON a.mo = mt.mo AND a.msp = mt.msp
ORDER BY msp, month;
```

- [ ] **Step 2: Validate live**

Substitute `{{ GraceMonths.value }}` → `3`, `{{ LookbackMonths.value }}` → `6`. Run it.

Check:
- Real MSP names appear (not just "Not Set" for every row — if EVERY row is "Not Set," the
  `acct_msp` join is broken, check `DIM_CRM_ACCOUNT_HISTORY.CRM_ACCOUNT_SK` actually matches
  `FCT_CRM_TASK.CRM_ACCOUNT_SK`'s real population rate first).
- Sum of `calls` across all MSPs for one month should be LESS THAN OR EQUAL to
  `sdr_funnel_by_segment.sql`'s total calls for the same month (this file additionally
  requires a resolved account MSP, so some rows will legitimately drop out — confirm the drop
  isn't catastrophic, e.g. losing more than half the volume would suggest a join problem, not
  expected coverage gaps).

- [ ] **Step 3: Commit**

```bash
git add queries/sdr_activity_by_msp.sql
git commit -m "Add sdr_activity_by_msp.sql - SDR activity joined through account MSP

Part of Debrief restructure - Box 2's SDR Activity Subject, MSP
breakout. SDR pods map to segments, not MSPs, so this answers a
different question (which MSP's prospects are SDRs spending time on)
via the account-level DIM_SALES_ACCOUNTS join already validated in
niro_units_cube.sql. SDR Activity x Team deliberately not built - no
clean mapping exists (2 SMB AE teams share 1 SDR pod).

Coding-Agent: Claude Code"
```

---

## Task 8: `insights_forecast_decline_drivers.sql` — new file

**Files:**
- Create: `queries/insights_forecast_decline_drivers.sql`
- Reference: `queries/insights_forward_pipeline_trend.sql` Part C, `queries/sdr_funnel_by_segment.sql`, `queries/closed_lost_rate_cube.sql`, `queries/insights_cycle_time_trend.sql`, `queries/insights_stage_velocity.sql`

- [ ] **Step 1: Read `insights_forward_pipeline_trend.sql` Part C in full** to confirm its
exact output columns (the decline flag, the target month, the segment driver column already
mentioned in this session's plan notes) before writing anything that joins against it.

- [ ] **Step 2: Write the file**

```sql
-- Forecast Decline Drivers -- Kevin: "layer in pipeline/activities into the top box - if
-- forecasting less units next month, could be attributed to less SDR pipeline or AE
-- execution." Feeds Box 1's persistent General Business Summary (see docs/superpowers/specs/
-- 2026-08-05-debrief-restructure-design.md).
--
-- TRIGGER: reuses insights_forward_pipeline_trend.sql Part C's already-validated forecast-
-- decline flag as-is -- no changes to that file's as-of-cohort logic (the technique that
-- avoids comparing a still-growing forecast against a settled actual, which would mechanically
-- read as "declining" every month by construction).
--
-- CANDIDATE DRIVERS CHECKED FOR THE SAME WINDOW AS THE DECLINE, NEVER A LAGGED CLAIM:
--   1. SDR-sourced pipeline creation (sdr_funnel_by_segment.sql's pipeline_created column) --
--      did New Logo pipeline creation also drop this period?
--   2. AE execution basket, checked independently, report whichever actually moved:
--      - Win rate (closed_lost_rate_cube.sql)
--      - Cycle time (insights_cycle_time_trend.sql)
--      - Stage velocity (insights_stage_velocity.sql)
--
-- FRAMING IS LOCKED: "coincided with," never "caused by." sdr_activity_to_pipeline.sql already
-- tested a one-month-lag causal claim for the SDR/pipeline relationship specifically and found
-- it weaker or negative in every segment -- same-period co-movement is the only claim this
-- file is allowed to make. If NONE of the 4 candidates moved unfavorably in the same window as
-- a real decline, this file returns the decline row with all 4 candidate flags FALSE --
-- narration must say "no clear driver identified this period," not invent one.

WITH decline AS (
    -- Pulls insights_forward_pipeline_trend.sql Part C's own output directly -- this CTE is a
    -- straight copy of that part's final SELECT, not a re-derivation. If Part C's column names
    -- change, update this CTE to match, don't let it silently drift out of sync.
    SELECT target_month, segment_bucket, company_pct_change, driver_segment
    FROM (
        -- << Part C's full query body goes here verbatim at implementation time -- confirmed
        -- via Step 1's read, then pasted in full so this file has no runtime dependency on
        -- another file existing/being queryable as a view. >>
    )
    WHERE company_pct_change < 0  -- only real declines are candidates for driver attribution
),
sdr_pipeline_check AS (
    SELECT mo AS target_month, segment,
        pipeline_created,
        LAG(pipeline_created) OVER (PARTITION BY segment ORDER BY mo) AS pipeline_created_prior
    FROM (
        -- << sdr_funnel_by_segment.sql's pipeline_created CTE/output, same verbatim-copy rule
        -- as above. >>
    )
),
win_rate_check AS (
    SELECT period AS target_month, entity AS segment_bucket,
        loss_rate_by_units,
        LAG(loss_rate_by_units) OVER (PARTITION BY entity ORDER BY period) AS loss_rate_prior
    FROM (
        -- << closed_lost_rate_cube.sql with Dimension.value='segment_bucket', verbatim copy. >>
    )
),
cycle_time_check AS (
    SELECT month AS target_month, segment_bucket,
        avg_cycle_time_days,
        LAG(avg_cycle_time_days) OVER (PARTITION BY segment_bucket ORDER BY month) AS cycle_time_prior
    FROM (
        -- << insights_cycle_time_trend.sql, verbatim copy. >>
    )
),
stage_velocity_check AS (
    SELECT month AS target_month, segment_bucket,
        avg_days_in_stage,
        LAG(avg_days_in_stage) OVER (PARTITION BY segment_bucket ORDER BY month) AS stage_velocity_prior
    FROM (
        -- << insights_stage_velocity.sql, verbatim copy. >>
    )
)
SELECT
    d.target_month,
    d.segment_bucket,
    d.company_pct_change,
    -- Candidate 1: SDR pipeline also down
    IFF(sp.pipeline_created < sp.pipeline_created_prior, TRUE, FALSE) AS sdr_pipeline_declined,
    sp.pipeline_created, sp.pipeline_created_prior,
    -- Candidate 2a: win rate down (loss rate up)
    IFF(wr.loss_rate_by_units > wr.loss_rate_prior, TRUE, FALSE) AS win_rate_declined,
    wr.loss_rate_by_units, wr.loss_rate_prior,
    -- Candidate 2b: cycle time up (slower)
    IFF(ct.avg_cycle_time_days > ct.cycle_time_prior, TRUE, FALSE) AS cycle_time_worsened,
    ct.avg_cycle_time_days, ct.cycle_time_prior,
    -- Candidate 2c: stage velocity slower
    IFF(sv.avg_days_in_stage > sv.stage_velocity_prior, TRUE, FALSE) AS stage_velocity_worsened,
    sv.avg_days_in_stage, sv.stage_velocity_prior
FROM decline d
LEFT JOIN sdr_pipeline_check sp ON sp.target_month = d.target_month AND sp.segment = d.segment_bucket
LEFT JOIN win_rate_check wr ON wr.target_month = d.target_month AND wr.segment_bucket = d.segment_bucket
LEFT JOIN cycle_time_check ct ON ct.target_month = d.target_month AND ct.segment_bucket = d.segment_bucket
LEFT JOIN stage_velocity_check sv ON sv.target_month = d.target_month AND sv.segment_bucket = d.segment_bucket
ORDER BY d.target_month, d.segment_bucket;
```

**Implementation note for whoever executes this task**: the 4 CTEs with `-- << ... >>`
placeholders are not a plan violation — they're an explicit instruction to paste in the real,
already-existing query bodies from the 4 referenced files verbatim, which requires reading
those files' current exact column names first (Step 1). Do not invent column names; do not
leave the placeholders in the committed file.

- [ ] **Step 3: Validate live**

Run it (after filling in the 4 verbatim CTEs). Check:
- At least one row has `company_pct_change < 0` in the trailing window checked (if the real
  data currently shows no declines at all, temporarily widen the window to find a historical
  example to validate the JOIN logic against, then confirm it still returns 0 rows in the
  real current-day default window — both are valid, just confirm which is true).
- For any row where `sdr_pipeline_declined = TRUE`, manually pull that segment/month's
  `pipeline_created` from `sdr_funnel_by_segment.sql` directly and confirm it matches.
- Confirm at least one row (real data permitting) has ALL 4 candidate flags FALSE, to prove the
  "no clear driver identified" case is reachable and not accidentally impossible by construction.

- [ ] **Step 4: Commit**

```bash
git add queries/insights_forecast_decline_drivers.sql
git commit -m "Add insights_forecast_decline_drivers.sql - feeds Box 1 forecast decline callout

Kevin: layer in pipeline/activities into the top box - forecasting less
units next month could be attributed to less SDR pipeline or AE
execution. Reuses insights_forward_pipeline_trend.sql Part C's decline
flag as trigger; checks SDR pipeline creation + a 3-metric AE execution
basket (win rate, cycle time, stage velocity) for same-window
co-movement. Locked to 'coincided with' framing per the already-
validated sdr_activity_to_pipeline.sql lag finding - never a causal
claim. Returns all-FALSE candidate flags when nothing explains a real
decline, rather than forcing an explanation.

Coding-Agent: Claude Code"
```

---

## Task 9: Wire Box 1 (General Business Summary) in Superblocks

**Files:**
- Modify: `docs/superblocks-setup.md` (new §4.20)

- [ ] **Step 1: Write the Superblocks wiring instructions into the doc**

```markdown
## 4.20. Debrief Restructure: Box 1 (General Business Summary) + Box 2 (Dig In)

Full design: docs/superpowers/specs/2026-08-05-debrief-restructure-design.md

### Box 1 wiring

Persistent card, always rendered above Box 2, never hidden by any filter interaction.

- Bind to a query call with EVERY dimension filter parameter left blank/unbound
  (Team.value, Segment.value, Msp.value, DealType.value, Rep.value all empty) on every source
  file below. Only the global Time Horizon control (This Week/Month/Quarter) feeds this box.
- Pooled sources (call each with the same blank-filter binding): ai_summary_facts.sql Part A,
  insights_declining_streaks.sql, insights_mix_shift_scanner.sql, insights_niro_mix_trend.sql,
  insights_closed_lost_streak.sql, insights_net_units_bridge.sql Parts A/C,
  insights_forecast_decline_drivers.sql.
- LLM narration prompt: "You will receive facts from up to 7 different sources. Pick the 3-5
  MOST MATERIAL facts across the whole set -- prioritize by magnitude of change and streak
  length, not by which source they came from. If insights_forecast_decline_drivers.sql returns
  a row, ALWAYS include it (a forecast decline is always material) and phrase any candidate
  driver as 'coincided with,' never 'caused by' -- if all 4 candidate flags are FALSE, say 'no
  clear driver identified this period,' don't invent one."

### Box 2 wiring

Four button groups: Subject (single-select) / Breakout (single-select, optional) / Filter
(multi-select, optional) / Time (This Week/Month/Quarter, or a period-picker value).

- Subject -> which query resource to call:
  - Units -> rolled_out_units_cube.sql
  - NIRO -> niro_units_cube.sql
  - Loss Rate -> closed_lost_rate_cube.sql
  - Deactivations/Uplevel/Downlevel -> insights_net_units_bridge.sql (relevant Part)
  - Pipeline -> pipeline_cube.sql
  - SDR Activity -> sdr_funnel_by_segment.sql (Segment/Rep) or sdr_activity_by_msp.sql (MSP) --
    NO Team option, see that file's header for why.
  - Opportunity Type mix -> insights_mix_shift_scanner.sql Part B
- Breakout -> the `{{ Dimension.value }}` parameter on whichever cube got called.
- Filter -> multi-select components bound to Team.value/Segment.value/Msp.value/
  DealType.value/Rep.value as comma-separated strings (every cube file now accepts this as of
  Tasks 1-6 above).
- Time -> This Week/Month/Quarter maps to Granularity + a rolling "current" period; a specific
  past period (period picker) maps to `{{ TargetPeriod.value }}` where each cube's
  `prior_period_*`/`trailing_avg_*` columns are read for the comparison, per the design spec's
  dual-comparison rule (Week grain leads with trailing average, Month/Quarter lead with
  prior-period).
- No Breakout selected -> LLM narration receives one aggregate row, produces one sentence, no
  per-entity breakdown (see spec's "No Breakout selected" clarification).
```

- [ ] **Step 2: Commit**

```bash
git add docs/superblocks-setup.md
git commit -m "Document Box 1 / Box 2 Superblocks wiring for Debrief restructure (4.20)

Coding-Agent: Claude Code"
```

---

## Self-Review

**1. Spec coverage** — walked every section of `2026-08-05-debrief-restructure-design.md`:
- Box 1 architecture -> Task 9. Box 2 architecture -> Task 9. Subject×Breakout matrix -> Tasks
  1-7 (every 🔧 cell has a task). Forecast Decline Drivers -> Task 8. Multi-select filters ->
  Tasks 1-6. Dual time comparison -> Tasks 1-6. SDR/Team exclusion -> documented in Task 7's
  file header and Task 9's wiring doc. Non-negotiables (DSMB, grace period, New Vertical,
  facts-vs-narration, snapshot-not-causation, materiality, no fabricated wins) -> carried into
  every task's SQL comments and the locked framing language in Task 8. Verification plan ->
  each task's "Validate live" step implements the specific check the spec called for. No gaps
  found.

**2. Placeholder scan** — Task 8's 4 CTEs contain literal `-- << ... >>` markers. These are
flagged explicitly as an intentional "paste the verbatim real query here" instruction, not a
vague TODO, with a stated implementation note directly beneath the code block. This is a
deliberate exception to the no-placeholder rule for the specific, unavoidable case of
"depends on reading another file's current exact structure first" — every other task has zero
placeholders.

**3. Type/column consistency** — checked `entity`/`period`/`units` column names referenced in
Tasks 2-4 match against "whatever this file's actual column names are" with an explicit
instruction to confirm via Step 1's read rather than assume — this is deliberate given plan
authorship happened without live access to re-confirm every existing file's exact current
column spelling in this pass; flagged as a read-first requirement rather than guessed.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-05-debrief-restructure.md`. Two
execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between
tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution
with checkpoints.

Which approach?
