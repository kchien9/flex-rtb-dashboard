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
| `queries/activity_cube.sql` | Calls/Emails/Meetings/Demos, by rep and period | Calls/Emails via `FCT_CRM_TASK`, Demos via `MEETING_SUBTYPE = 'Sales \| Demo'`; caught a real join-fan-out bug building this, see file header |
| `queries/pipeline_forecast.sql` | "The Road Ahead" — open pipeline by expected go-live month | Deliberately unweighted (no stage win-rate data to weight against yet — see `project_pipeline_win_rates.md`); real coverage gap on team attribution, flagged in file |
| `queries/insights_activity_to_outcome.sql` | Rep-level meeting pacing + New Logo meetings-vs-units trend | Meeting→opportunity attribution is approximate (same-account, ±45 days) — stated plainly, not hidden |

**Two open items blocking full build-out of the newest features — need Kevin's input, can't get these from Snowflake:**
1. **Spiff/intervention dates** (e.g. "we dropped a team spiff to push toward RealPage") aren't in Snowflake anywhere — `insights_mix_shift.sql`'s trend needs a manual annotation for when an intervention started, supplied by Kevin, not derived from data.
2. **Quota/target numbers** ("are we gonna hit our number") — no quota/target field found in any table checked so far. Needs Kevin to say where these live (comp config workbook? a Salesforce field? somewhere else?) before a pacing-to-goal view can be built.

### Paused — lower priority, committed but not blocking

| File | What it is | Status |
|---|---|---|
| `queries/mtr_bullets.sql` | Auto-drafted "biggest win" bullets for Sham's MTR doc | Built, works, not urgent |
| `queries/oneonone_prep.sql` | Per-manager team trend + departure detection, for Sham's 1:1s with Brandon/Dana/Rory/Sebastian/Hans | Built, works for Brandon/Rory/Sebastian pods. Dana's pod name and Hans's SDR-side equivalent still unresolved — pick back up later |

## Before you wire anything up — must-fix items

1. ~~`performance_cube.sql`'s BP-period boundaries were hardcoded placeholder dates~~ — **fixed 2026-07-27**, now self-computing off a verified date formula, no reference table, never goes stale.
2. **Apostrophe escaping is unresolved at the Superblocks layer.** Every filter in this repo is written assuming Mustache string substitution (`'{{Value}}'`), which breaks on real values like "Brandon's Team" unless escaped. Confirm Superblocks' actual bind-parameter syntax for the Snowflake connector before wiring filters — if it supports named/positional bind params, use those instead of raw Mustache for every value filter (not the `{{ Dimension.value }}` column-name selector, which has to stay Mustache since it's a raw identifier, not a value — constrain that dropdown's options in Superblocks so it's never free text). **This is now the single biggest open item blocking P0.**
3. ~~DSMB exclusion is not yet applied to `performance_cube.sql`~~ — **fixed 2026-07-28** (Pattern B pmc_size join via `DIM_CRM_ACCOUNT_HISTORY.PMC_ID`, not `TOTAL_COMPANY_UNITS` which is a deal-time snapshot). **Repo-wide DSMB audit completed 2026-07-31** per Kevin's explicit ask ("make sure DSMB is not included anywhere — in no tables, in no numbers, in no AI summaries"): every query file was checked against the standard `pmc_size` pattern (Pattern A on `PROPERTY_BP_MONTH_STATS`, Pattern B via `DIM_CRM_ACCOUNT_HISTORY` on `FCT_CRM_OPPORTUNITY`). 11 real gaps found and fixed: `mtr_bullets.sql`, `pipeline_forecast.sql`, `insights_closed_lost_trend.sql`, `closed_lost_analysis.sql`, `closed_won_by_rep.sql`, `rep_detail.sql`, `oneonone_prep.sql`, `ai_summary_facts.sql` (Parts C/D), `new_opportunities_by_msp.sql`, `pipeline_stage_flow_weekly.sql`, `sales_cycle_time_by_segment.sql` — the last three were excluding DSMB only via a team-label CASE (the wrong mechanism: a DSMB account tagged under a real team's label would slip through), not by account size. Any NEW query touching a segment/team/rep/MSP total must include this join — check `performance_cube.sql`'s header for the reference pattern before writing one from scratch.

## Known data quality gotchas

- **Team filter needs care**: `HUBSPOT_STATIC_TEAM_NAME_DEAL` is pod-level (Brandon's Team, SMB Account Executives 1/2, DSMB 1-5), not manager names except for personalized pods. Confirmed mapping: SMB Account Executives 1 = Sebastian Bohlmann, SMB Account Executives 2 = Rory Averett. Dana's and Hans's pods unconfirmed.
- **Segment**: use `HUBSPOT_COMPANY_SEGMENT`, not `ACCOUNT_SEGMENT` — they disagree significantly. On the new tables, segment resolution via `DIM_CRM_ACCOUNT_HISTORY` is currently ~69% "Unknown" for closed-won deals — don't trust new-table Segment cuts yet.
- **Deal-level MSP field is dirty** — some opportunity rows have multiple MSP values jammed into one field. Use `PMS` on the rolled-out-units table for MSP slicing instead.
- **"Did a deal roll out" — use `FLEX.STG_SALESFORCE.STG_SALESFORCE__IMPLEMENTATION`**, not inference from `PROPERTY_BP_MONTH_STATS` flags. That inference path cost six rounds of real bugs (wrong join key, missing history, BP-vs-calendar mismatch, property dedup/linking, Uplevel deals not flagged the same way, ambiguous duplicate deal names) before landing on the actual authoritative source. Full writeup in `watchlist_large_deals_at_risk.sql`'s header comment — read it before touching implementation-status logic anywhere else in this repo.
- **PMC size for DSMB exclusion**: use each PMC's *current* live unit total (summed fresh), not the stored `HUBSPOT_DEAL_TOTAL_COMPANY_UNITS` field — that's a deal-time snapshot that disagrees with current reality on ~13% of PMCs.
- **Rep-level status**: for departure/reassignment checks, use `FLEX.STG_SALESFORCE.STG_SALESFORCE__USER`'s live `IS_ACTIVE`/`TEAM_NAME`, not the Rippling comp roster (`comp_config_v4.xlsx`) — that updates on a payroll cadence and goes stale on real-time reassignments.
- **`DIM_EMPLOYEE_HISTORY` has no active/inactive concept at all, and carries MULTIPLE `IS_CURRENT=TRUE` rows per person** (one per source system — Salesforce/HubSpot/Jira each write their own row; confirmed live that 100% of `FCT_CRM_TASK`/`FCT_CRM_MEETING`/`FCT_CRM_OPPORTUNITY`'s `EMPLOYEE_SK` values resolve to the Salesforce-sourced rows specifically). A naive `WHERE IS_CURRENT = TRUE` join lets departed reps (Zach Branson, Jacob Fidler, MJ Oommen, Jason Rosen — all confirmed departed but still surfacing in rep-level tables) and double-counted reps (Zach Branson had 2 current Salesforce rows across two SMB pods) straight through. Also: some reps are tagged into a real pod's `TEAM_NAME` for CRM/reporting convenience without being org-homed there — Saba Obaid shows `TEAM_NAME = 'Strategic Team'` but `PARENT_TEAM = 'Revenue'`, while every real Strategic AE has `PARENT_TEAM = 'Mid Market +'`. **Fixed everywhere 2026-07-29** via a standard `team_map` pattern (see `activity_vs_outcome_by_rep.sql`'s header for the full writeup): dedupe `DIM_EMPLOYEE_HISTORY` to one Salesforce-sourced row per `EMAIL`, join to a deduped `STG_SALESFORCE__USER` for real `TEAM_NAME`/`PARENT_TEAM`/`IS_ACTIVE`/`LAST_LOGIN_AT_UTC`, require `PARENT_TEAM = 'Mid Market +'` for the Strategic pod specifically, and apply the standard `{{ GraceMonths.value }}` (default 2) departure grace period. Any NEW rep-level query must use this pattern, not a direct `DIM_EMPLOYEE_HISTORY` join.
- **No verified "segment" field exists on the new tables yet.** `insights_stage_velocity.sql` buckets `FLEX.SALES.FCT_CRM_OPPORTUNITY.STATIC_TEAM_NAME` into SMB / DSMB / Strategic-MM as a segment proxy (same logic as the old-table team-as-segment pattern elsewhere in this repo). Pods that aren't a real AE segment (Partner Success, Rev Ops, Channel Sales, House Accounts, SDR-only pods) are excluded outright, not lumped into "Other."
- **Stuck-deal / stale-pipeline lists surface zombie deals from departed reps** — validated live: several of the longest-"stuck" negotiation deals belong to reps already confirmed departed in `oneonone_prep.sql` (Jacob Fidler, Redding Tews). These are deals nobody closed out, not real 700+ day negotiations. **Fixed 2026-07-29** in `insights_stage_velocity.sql` Part B — the deal stays on the watch list (it's real, still needs someone to close it out), but the `rep` field shows NULL instead of a departed person's name.
- **`FCT_CRM_OPPORTUNITY.UPDATED_AT_UTC` is NOT a real "last touched by a human" signal** — confirmed live on 3 opportunities open 541-821 days: all three had ZERO real tasks/meetings ever logged, yet `UPDATED_AT_UTC` read as "3 weeks ago" on every one (an automated field sync, not human activity). Use real last-activity (`MAX` of completed Task/Meeting dates on the account, falling back to `CREATED_AT_UTC` when there's never been any) instead — see `open_opportunities_by_segment.sql`. This is a much stricter filter and drops the "fresh open pipeline" number a lot (2.6M vs. the old, broken 14.8M) — that's real, not a bug.
- **`STATIC_TEAM_NAME` on OPEN (not yet closed) opportunities correlates almost perfectly with deal age**, not real team assignment timing — checked live: unattributed ("Not Set") open deals have a median age of 36 days (fresh, not-yet-routed leads), while every attributed segment (Strategic/MM-Ent/SMB) has a median age of 431-551 days. This means segment-level cuts of OPEN pipeline may not be a meaningful view — flagged to Kevin 2026-07-29, not yet resolved, don't build more segment-of-open-pipeline features on this field without revisiting.
- **`HUBSPOT_DEAL_OWNER` is not a clean per-person field -- it can carry a large BLOCK of deals
  tagged under a team that isn't really that person's** -- confirmed live TWICE while building
  `possible_departures.sql`: "Cory Baach" and "Evan Klein" are both real, current, correctly-
  Salesforce-tagged reps (Strategic Team), but each carries a chunk of `PROPERTY_BP_MONTH_STATS`
  rows attributed to their name under a DIFFERENT `HUBSPOT_STATIC_TEAM_NAME_DEAL` (Evan Klein:
  675,483 units tagged "Brandon's Team" vs only 101,491 under his real "Strategic Team" in the
  current month alone -- a 6.6x bulk-attribution artifact). Don't infer a rep's "true" team from
  which tag has the most volume under their name, and don't build a cross-team "reassignment"
  detector off this field at the whole-org level -- it will produce false positives on
  perfectly fine, fully-active reps. STG_SALESFORCE__USER's TEAM_NAME (a live status field, not
  a deal-attribution guess) is the reliable source for "what team is this person on right now."
- **`rolled_out_units_cube.sql` outputs both `integrated_total_units` (STOCK — cumulative network total, never sum across months) and `new_integrated_units` (FLOW — this-period rollout, safe to sum)** in the same row. A "Rolled-Out Units" card must bind to `new_integrated_units` — confirmed live a Superblocks card was bound to the stock column instead, showing MM/Ent at 3.5M when the real rolled-out-this-month number is ~27-62K. Same underlying stock-vs-flow confusion as the earlier 30M-unit incident.
- **Aggregating a per-dimension monthly total and joining it back to a wider table on date alone fans out rows** — confirmed live bug in an early draft of `insights_mix_shift.sql`: joining a per-BP_MONTH-x-PMS table back to the base table on `BP_MONTH` only (not also `PMS`) multiplied every base row once per distinct PMS value that month, inflating `total_units` ~7x and corrupting every share metric silently. Fix: collapse to one row per grouping key FIRST, then join.
- **`FCT_CRM_OPPORTUNITY`'s per-stage timestamps (`QUALIFICATION_AT_UTC`/`DISCOVERY_AT_UTC`/`BUILDING_VALUE_AT_UTC`/`NEGOTIATION_AT_UTC`/`DEAL_REVIEW_AT_UTC`) are NOT reliably real stage-entry events for a large share of deals — DO NOT build a stage-to-stage conversion/funnel rate off them as-is.** Attempted 2026-07-30 (Kevin asked for "stage conversion rate" on the pipeline view); killed before shipping. Confirmed live: a "Duplicate Opportunity" deal created and closed same-day in July shows `Discovery/Building Value/Negotiation/Deal Review` all stamped four months in the FUTURE (Oct 28) — an impossible real event. Systemically, 58% of ALL closed-won deals (not just administrative cleanup closes) have all five stage dates identical to each other — including 92% of Strategic won deals, which this repo's own `sales_cycle_time_by_segment.sql` already confirmed have real multi-month cycles. Building a sequential-conversion-rate query on these fields produced a suspiciously uniform ~95-100% "conversion" at every stage for every segment — not a real signal, a backfill artifact (these fields appear to get bulk-stamped to satisfy a required-field validation at close, not written once per genuine stage transition). Don't re-attempt this without first getting the underlying Salesforce process/automation fixed at the source, or finding an independently-validated stage-history event table (none exists today — checked `INT_SALESFORCE__STAGE_SNAPSHOT`/`SNAPSHOT_SALESFORCE_STAGE`/`STG_SALESFORCE__OPPORTUNITY_STAGE`, all three are stage-picklist METADATA tables, not per-opportunity transition history).

## Superblocks wiring notes

Full step-by-step (datasource setup, every component you need to build, apostrophe-escaping
fix, build order, drill-down click wiring) is in **[`docs/superblocks-setup.md`](docs/superblocks-setup.md)**.
Quick summary:

- `{{ Component.value }}` = Mustache bindings to filter/dropdown components, same pattern as `flex-voyager`.
- `{{ Dimension.value }}` on the Rolled-Out Units Cube is a dropdown bound to a raw column name — this is what makes one query drive every slice. Constrain its options in Superblocks; never let it be free text.
- Drill-down: clicking a row sets a filter to that value and switches the next dimension level. Same query re-fires, no new query per drill level. Every drill chain should bottom out in `opportunity_drilldown.sql` — the actual deals behind the number.
- Team x MSP / Segment x Deal Type style matrix views: pick a primary "slice by" dimension, an optional "compare by" second dimension (turns the panel into a 2D table), everything else becomes a filter chip. Don't build a full N-dimensional pivot table — past 2 visual dimensions it stops being readable regardless of how capable the query is.
- Insights panel: run the insight queries on a schedule (daily/weekly, TBD) and bind the `callout` column to a text list at the top of the dashboard.
