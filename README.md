# RTB 2.0 Sales Leadership Dashboard

Superblocks app for Sham Desai (VP Sales): one place to see performance (meetings, pipeline,
closed-won/lost, rolled-out units) with full drill-up/down across every dimension, plus an
insights layer that proactively flags what needs attention instead of leaving Sham to find it.

Same stack as `flex-voyager`: Superblocks (UI) + Snowflake (read-only). Solo build.

**Scope for this build pass: get the core dashboard build-ready. Coaching/1:1 features are
lower priority — built and committed, but not blocking this week's work.**

## Docs

- Pilot scoping doc (exec-facing): https://docs.google.com/document/d/18CgqX4YoVNY44hkIjf6umtcVn-4q7gwkA_OvryEpXrY (tab "RTB 2.0 Dashboard")
- Technical build plan (architecture, roadmap): https://docs.google.com/document/d/1m24kH_Fr5ZJORWvsXnMvCiwg3cd2UIWLN1Cg28YjTjk
- Replatform table mapping + gotchas: `docs/replatform-notes.md`

## Build order

### P0 — build this first

| File | Feeds | Notes |
|---|---|---|
| `queries/performance_cube.sql` | Performance page — meetings/pipeline/closed-won/lost, Week/Month/Quarter toggle, BP-aligned | BP periods are self-computing (no reference table, never goes stale) — ready |
| `queries/rolled_out_units_cube.sql` | Rolled-Out Units page — recap/new/MSP/segment/team/deal-type, one query drives every slice via `{{ Dimension.value }}` | DSMB-excluded (account size <=750), filter-layering validated with 3+ filters at once |

### P1 — build once P0 is live

| File | Feeds | Notes |
|---|---|---|
| `queries/insights_trend_flags.sql` | Insights panel — spike/dip callouts | DSMB-excluded, BP-month resolved from data not `CURRENT_DATE()` |
| `queries/insights_driver_concentration.sql` | Insights panel — "who's actually driving this" | DSMB-excluded |
| `queries/insights_activity_correlation.sql` | Insights panel — activity<->units correlation + rep drill-in | New `FLEX.SALES.*` tables, real validated example (Strategic Team) |
| `queries/insights_closed_lost_trend.sql` | Insights panel — is loss rate rising, and why | Rate not raw count; `CLOSED_LOST_REASON` breakdown; current in-progress month dropped from the trend line |
| `queries/insights_stage_velocity.sql` | Insights panel — deal-cycle time trend + currently-stuck deals | WITHIN-segment only (never Strategic vs. SMB — different cycle lengths are structural, not a signal); censoring-safe (Part A resolved-only, Part B is the open-ended complement) |
| `queries/insights_mix_shift.sql` | Insights panel — Sham's composition "pulse" (expansion share, recapture share, MSP concentration) | DSMB-excluded; see header for a real fan-out bug caught while validating |
| `queries/watchlist_large_deals_at_risk.sql` | Watch List tab — large deals that failed/stalled | Built on `FLEX.STG_SALESFORCE.STG_SALESFORCE__IMPLEMENTATION` (the real source of truth — see bug history in the file, six rounds of real bugs before landing here) |
| `queries/units_closed_forecast_bridge.sql` | "Units closed, awaiting rollout" forward-looking context | Validated median close->rollout lag: 12 days |
| `queries/opportunity_drilldown.sql` | Bottom of every drill chain — the actual deals behind any unit slice | Aggregated to opportunity grain via `FCT_CRM_OPPORTUNITY_LINE_ITEM`; ties out to `rep_leaderboard.sql` (validated) |
| `queries/rep_leaderboard.sql` | Rep-level ranked view — on-demand, not default | Sham manages managers by default, but wanted rep-level access available; wire as a drill-through, not a headline panel |

### Paused — lower priority, committed but not blocking

| File | What it is | Status |
|---|---|---|
| `queries/mtr_bullets.sql` | Auto-drafted "biggest win" bullets for Sham's MTR doc | Built, works, not urgent |
| `queries/oneonone_prep.sql` | Per-manager team trend + departure detection, for Sham's 1:1s with Brandon/Dana/Rory/Sebastian/Hans | Built, works for Brandon/Rory/Sebastian pods. Dana's pod name and Hans's SDR-side equivalent still unresolved — pick back up later |

## Before you wire anything up — must-fix items

1. ~~`performance_cube.sql`'s BP-period boundaries were hardcoded placeholder dates~~ — **fixed 2026-07-27**, now self-computing off a verified date formula, no reference table, never goes stale.
2. **Apostrophe escaping is unresolved at the Superblocks layer.** Every filter in this repo is written assuming Mustache string substitution (`'{{Value}}'`), which breaks on real values like "Brandon's Team" unless escaped. Confirm Superblocks' actual bind-parameter syntax for the Snowflake connector before wiring filters — if it supports named/positional bind params, use those instead of raw Mustache for every value filter (not the `{{ Dimension.value }}` column-name selector, which has to stay Mustache since it's a raw identifier, not a value — constrain that dropdown's options in Superblocks so it's never free text). **This is now the single biggest open item blocking P0.**
3. **DSMB exclusion is not yet applied to `performance_cube.sql`** (the new-table Performance side) — only the old-table queries have it. Needs a live PMC-size check via `DIM_CRM_ACCOUNT_HISTORY.TOTAL_COMPANY_UNITS` or equivalent before this dashboard is SMB+-scoped end to end, not just on the units side.

## Known data quality gotchas

- **Team filter needs care**: `HUBSPOT_STATIC_TEAM_NAME_DEAL` is pod-level (Brandon's Team, SMB Account Executives 1/2, DSMB 1-5), not manager names except for personalized pods. Confirmed mapping: SMB Account Executives 1 = Sebastian Bohlmann, SMB Account Executives 2 = Rory Averett. Dana's and Hans's pods unconfirmed.
- **Segment**: use `HUBSPOT_COMPANY_SEGMENT`, not `ACCOUNT_SEGMENT` — they disagree significantly. On the new tables, segment resolution via `DIM_CRM_ACCOUNT_HISTORY` is currently ~69% "Unknown" for closed-won deals — don't trust new-table Segment cuts yet.
- **Deal-level MSP field is dirty** — some opportunity rows have multiple MSP values jammed into one field. Use `PMS` on the rolled-out-units table for MSP slicing instead.
- **"Did a deal roll out" — use `FLEX.STG_SALESFORCE.STG_SALESFORCE__IMPLEMENTATION`**, not inference from `PROPERTY_BP_MONTH_STATS` flags. That inference path cost six rounds of real bugs (wrong join key, missing history, BP-vs-calendar mismatch, property dedup/linking, Uplevel deals not flagged the same way, ambiguous duplicate deal names) before landing on the actual authoritative source. Full writeup in `watchlist_large_deals_at_risk.sql`'s header comment — read it before touching implementation-status logic anywhere else in this repo.
- **PMC size for DSMB exclusion**: use each PMC's *current* live unit total (summed fresh), not the stored `HUBSPOT_DEAL_TOTAL_COMPANY_UNITS` field — that's a deal-time snapshot that disagrees with current reality on ~13% of PMCs.
- **Rep-level status**: for departure/reassignment checks, use `FLEX.STG_SALESFORCE.STG_SALESFORCE__USER`'s live `IS_ACTIVE`/`TEAM_NAME`, not the Rippling comp roster (`comp_config_v4.xlsx`) — that updates on a payroll cadence and goes stale on real-time reassignments.
- **No verified "segment" field exists on the new tables yet.** `insights_stage_velocity.sql` buckets `FLEX.SALES.FCT_CRM_OPPORTUNITY.STATIC_TEAM_NAME` into SMB / DSMB / Strategic-MM as a segment proxy (same logic as the old-table team-as-segment pattern elsewhere in this repo). Pods that aren't a real AE segment (Partner Success, Rev Ops, Channel Sales, House Accounts, SDR-only pods) are excluded outright, not lumped into "Other."
- **Stuck-deal / stale-pipeline lists will surface zombie deals from departed reps** — validated live: several of the longest-"stuck" negotiation deals belong to reps already confirmed departed in `oneonone_prep.sql` (Jacob Fidler, Redding Tews). These are deals nobody closed out, not real 700+ day negotiations. Worth a "still assigned to a departed rep" flag if this becomes a real feature.
- **Aggregating a per-dimension monthly total and joining it back to a wider table on date alone fans out rows** — confirmed live bug in an early draft of `insights_mix_shift.sql`: joining a per-BP_MONTH-x-PMS table back to the base table on `BP_MONTH` only (not also `PMS`) multiplied every base row once per distinct PMS value that month, inflating `total_units` ~7x and corrupting every share metric silently. Fix: collapse to one row per grouping key FIRST, then join.

## Superblocks wiring notes

Full step-by-step (datasource setup, every component you need to build, apostrophe-escaping
fix, build order, drill-down click wiring) is in **[`docs/superblocks-setup.md`](docs/superblocks-setup.md)**.
Quick summary:

- `{{ Component.value }}` = Mustache bindings to filter/dropdown components, same pattern as `flex-voyager`.
- `{{ Dimension.value }}` on the Rolled-Out Units Cube is a dropdown bound to a raw column name — this is what makes one query drive every slice. Constrain its options in Superblocks; never let it be free text.
- Drill-down: clicking a row sets a filter to that value and switches the next dimension level. Same query re-fires, no new query per drill level. Every drill chain should bottom out in `opportunity_drilldown.sql` — the actual deals behind the number.
- Team x MSP / Segment x Deal Type style matrix views: pick a primary "slice by" dimension, an optional "compare by" second dimension (turns the panel into a 2D table), everything else becomes a filter chip. Don't build a full N-dimensional pivot table — past 2 visual dimensions it stops being readable regardless of how capable the query is.
- Insights panel: run the insight queries on a schedule (daily/weekly, TBD) and bind the `callout` column to a text list at the top of the dashboard.
