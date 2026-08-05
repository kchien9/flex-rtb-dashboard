# Debrief Restructure: Persistent Summary + Composable Dig-In — Design Spec

## Context

Current Debrief tab is one AI-summary box driven by dropdown filters (Segment/MSP/Team lens +
Deal Type/Unit Type refinements). Kevin's complaint: "since its only one box it will disappear
every time he switches filters" — Sham loses whatever summary he was looking at the moment he
changes a filter, and there's no way to see a dimension-agnostic "what's actually going on"
view without picking a specific lens first.

The ask evolved over several rounds into a clear two-box architecture, then expanded to "any
dimension possible" for the drill-in box. This spec captures the final, agreed shape.

## Architecture

### Box 1 — General Business Summary (persistent)

Always visible, above Box 2. Never filtered by Segment/Team/MSP/Rep/Deal Type/Unit Type — its
job is "what does a business leader need to know right now," not a slice of the business.

**Does respond to Time Horizon** (This Week / This Month / This Quarter, the global top-bar
control) — switching horizon changes which "now" period the summary is about, but never
introduces a dimension filter.

**Sources** (all already built, run with every dimension filter blank):
- `ai_summary_facts.sql` Part A — company-wide unit trend
- `insights_declining_streaks.sql`, `insights_mix_shift_scanner.sql`,
  `insights_niro_mix_trend.sql`, `insights_closed_lost_streak.sql`,
  `insights_net_units_bridge.sql` Parts A/C — all already scan every entity within their
  dimension without requiring a filter; run unfiltered here and pool the results
- A new same-month SDR-activity/pipeline co-movement check (see below)
- A new forecast-decline driver-candidate check (see "Forecast decline drivers" below) —
  Kevin: "layer in pipeline/activities... in the top box it can be like forecasting less units
  next month, could be attributed to less SDR pipeline, or AE execution."

### Forecast decline drivers (new fact block, feeds Box 1 conditionally)

**Trigger**: `insights_forward_pipeline_trend.sql` Part C already flags a real forecast
decline for a target month — reuse that flag as-is, no changes to its already-validated
as-of-cohort logic (the technique that avoids comparing a still-growing forecast against a
settled actual, which would mechanically read as "declining" every month).

**When a decline fires, check for candidate drivers in the SAME window** — never a lagged
claim, same rule as the SDR framing below:
- **SDR-sourced pipeline**: did New Logo pipeline creation from `sdr_funnel_by_segment.sql`/
  `sdr_activity_to_pipeline.sql` also drop this period?
- **AE execution basket** — 3 already-built proxies, checked independently, report whichever
  actually moved unfavorably (not a single forced metric):
  - Win rate (`closed_lost_rate_cube.sql`)
  - Cycle time (`insights_cycle_time_trend.sql`)
  - Stage velocity (`insights_stage_velocity.sql`)

**Output**: zero, one, or several candidate drivers per decline — list whichever genuinely
co-moved, in "coincided with" language ("alongside a drop in SDR-sourced pipeline" / "alongside
a longer average sales cycle"), never "caused by." **If nothing in the basket moved
unfavorably, say so plainly** ("no clear driver identified this period") — don't force an
explanation onto an unexplained decline, same "no fabricated wins/explanations" rule as
everywhere else in this repo.

**Narration**: pick the 3-5 most material facts across the whole pooled set — not everything,
not a dump. "Material" = same materiality floors each source file already enforces (this box
doesn't invent a new bar, it just doesn't show items below the bar every source already sets).

### Box 2 — Dig In (composable, multi-select)

Four button groups, not one flat pool — a flat pool can't express "MSP trend, by segment, for
the SMB team, this month" unambiguously (that sentence has 4 different roles bundled into it).

1. **Subject** (single-select) — what to look at: Units (New+Recap), NIRO, Loss Rate,
   Deactivations, Uplevel-to-Integrated, Downlevel-to-NIRO, Pipeline, SDR Activity, Opportunity
   Type mix.
2. **Breakout** (single-select, optional) — split the subject by: Segment, Team, MSP, Rep.
3. **Filter** (multi-select, optional) — narrow to specific values within any dimension
   (e.g., Team = Sebastian's Team, MSP = AppFolio + Yardi). Multiple filters combine with AND
   across dimensions, OR within a dimension (picking 2 MSPs means "either of these").
4. **Time** — This Week / This Month / This Quarter, OR a specific past period via a period
   picker (see Time section below). Independent of Box 1's Time Horizon — Sham can view Box 1
   at "This Month" while digging into "Q1 2026" in Box 2.

Clicking "Generate Digest" (or auto-refreshing on any button change — Superblocks
implementation detail, not a design decision) re-runs the underlying cube query for the chosen
Subject with the chosen Breakout/Filter/Time, and narrates the result.

**No Breakout selected** = a single aggregate number for the Subject, scoped to whatever
Filters/Time are set (e.g., Subject=Units, Filter=Team:Sebastian's, no Breakout → "Sebastian's
Team rolled out 47,933 units this month, up 18%," one line, no per-entity split). Breakout is
what turns that single number into a per-entity narrative.

## Subject × Breakout coverage matrix

| Subject | Segment | Team | MSP | Rep |
|---|---|---|---|---|
| Units (New+Recap) | built (`rolled_out_units_cube.sql`) | built | built | built |
| NIRO | built (`niro_units_cube.sql`) | built | built | built |
| Loss Rate | built (`closed_lost_rate_cube.sql`) | built | built | built |
| Deactivations / Uplevel / Downlevel | built (`insights_net_units_bridge.sql` Part B) | **new** | **new** | **new** |
| Pipeline | **new** (partial today, 3 inconsistent files) | **new** | **new** | **new** |
| SDR Activity | built (`sdr_funnel_by_segment.sql`, pod = segment) | **excluded, see note** | **new** | built (`sdr_activity_by_rep.sql`) |
| Opportunity Type mix | built (`insights_mix_shift_scanner.sql` Part B) | built | **new** | **new** |

**SDR Activity × Team excluded, not deferred** — SDR pods (SMB/MM-Ent/Strategic) map to
*segments*; Sebastian's and Rory's Teams both sit under the one SMB SDR pod. There's no clean
1:1 SDR-activity-by-AE-team number to show. Segment is the real cut for SDR data.

## New/extended files required

1. **`pipeline_cube.sql` (new)** — consolidates and replaces the partial coverage in
   `pipeline_forecast.sql`/`new_opportunities_by_msp.sql`/`insights_forward_pipeline_trend.sql`
   with one `{{ Dimension.value }}` cube (Segment/Team/MSP/Rep), same pattern as
   `rolled_out_units_cube.sql`. The 3 existing files' validated logic (open pipeline vs.
   closed-awaiting-rollout, the as-of cohort technique, New Vertical exclusion, 5-year sanity
   ceiling) gets carried into this file, not re-derived.
2. **`insights_net_units_bridge.sql` extended** — add Team, MSP, and Rep breakout options
   alongside the existing Segment one (Part B), same gaps-and-islands/partition technique
   already proven there. MSP breakout needs the account-level `DIM_SALES_ACCOUNTS` join
   (already validated in `niro_units_cube.sql`) since deactivated/uplevel/downlevel properties
   aren't guaranteed to carry a property-level `PMS` value.
3. **`sdr_activity_by_msp.sql` (new, or extend `sdr_funnel_by_segment.sql`)** — SDR activity
   joined through account MSP (via `DIM_SALES_ACCOUNTS`, same join as above) — "are SDRs
   spending time on AppFolio prospects vs. Yardi prospects."
4. **`insights_mix_shift_scanner.sql` extended** — add MSP and Rep breakout to the Opportunity
   Type mix (Part B currently Segment/Team only).
5. **Multi-select filter widening** — every cube file's single-value filter params
   (`{{ Team.value }} = '...'`, `{{ Segment.value }} = '...'`, etc.) need widening to
   `IN ({{ Team.value }})`-style multi-value lists, assuming Superblocks passes a multi-select
   as a comma-separated string the SQL can split. Touches `rolled_out_units_cube.sql`,
   `niro_units_cube.sql`, `closed_lost_rate_cube.sql`, the new `pipeline_cube.sql`, and any
   other file wired to Box 2.
6a. **`insights_forecast_decline_drivers.sql` (new)** — implements the Forecast Decline
   Drivers block above. Joins `insights_forward_pipeline_trend.sql` Part C's decline flag
   against the SDR-pipeline and AE-execution-basket checks for the same window. Facts only —
   returns the flag plus whichever candidate metrics moved, narration decides how to phrase it.
6. **Same-month SDR/pipeline co-movement fact (new, small)** — reuses
   `sdr_activity_to_pipeline.sql`'s already-validated same-month correlation finding
   (MM/Ent r=0.63) and `sdr_funnel_by_segment.sql`'s activity+pipeline_created columns.
   **Framing is locked**: same-period co-movement ("pipeline creation and SDR activity both
   dropped this month"), never a one-month-lag causal claim — `sdr_activity_to_pipeline.sql`
   already tested the lag and found it weaker/negative in every segment. Don't relitigate this
   without new evidence, same rule that file's own header already states.
7. **Time period picker + dual comparison (new)** — when Sham picks a specific past period in
   Box 2, compute:
   - Primary: prior period of the same type (last quarter if Quarter picked, last month if
     Month, last week if Week)
   - Secondary: trailing average (trailing 4 quarters / trailing 6 months / trailing 4 weeks)
   - **Week grain leads with the trailing average, not the single prior week** — a single prior
     week is too noisy to be the primary anchor (matches this dashboard's repeated small-sample
     findings elsewhere). Month and Quarter lead with prior-period, matching every existing MoM/
     QoQ convention already locked in across this repo.
   - Both numbers always shown, never just one — this feeds Sham's own upward reporting, so no
     single comparison gets to look cherry-picked.

## Non-negotiables carried over from existing repo conventions

- DSMB exclusion (`pmc_size` > 750 units) on every new/extended query.
- Departure grace period (`{{ GraceMonths.value }}`) on every rep/team join.
- New Vertical exclusion (`OPPORTUNITY_TYPE != 'New Vertical'`) on every deal-grain query.
- Facts-vs-narration separation — every new file only gathers facts; narration prompts do the
  writing. Never let the LLM invent or compute a number.
- Snapshot, not causation — every co-movement/correlation fact is captioned as "moved together
  this period," never "X caused Y," unless a real lag/causal test has been validated live (per
  the SDR framing above).
- Materiality floors on every new scanner/cube, validated against real data before shipping —
  same discipline as every file built this session.
- No fabricated wins — if a Subject×Breakout combination is flat or down, narration states that
  plainly rather than manufacturing a positive spin (same rule already locked for Shout Outs).

## Verification plan

- Validate every new/extended file live against Snowflake before committing, same standing
  discipline as this entire session.
- Cross-check `pipeline_cube.sql`'s totals against the 3 files it replaces for at least one
  dimension/period, to confirm no regression in the validated logic it's inheriting.
- Cross-check the net-units-bridge Team/MSP/Rep breakouts sum back to the existing Segment
  breakout's totals (no double-count/fan-out from the new joins).
- Spot-check the multi-select `IN (...)` widening doesn't change single-value-selection
  behavior (a 1-item multi-select should produce identical results to today's single dropdown).
- No test suite exists for this repo — verification is live Snowflake validation plus a
  Superblocks wiring handoff, consistent with every prior phase.

## Explicitly out of scope for this pass

- SDR Activity × Team (excluded on business-logic grounds, not deferred — see above).
- Any new causal claim beyond the same-month SDR co-movement fact already validated.
