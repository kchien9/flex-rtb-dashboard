# RTB 2.0 Sales Leadership Dashboard

Superblocks app for Sham Desai (VP Sales) and his managers: one place to see performance
(meetings, pipeline, closed-won/lost, rolled-out units) with full drill-up/down across every
dimension — recap vs. new, MSP, team, segment, rep, deal, new logo vs. expansion — plus an
insights layer that proactively calls out spikes, dips, trends, and driver concentration
instead of leaving Sham to dig for them.

Same stack as `flex-voyager`: Superblocks (UI) + Snowflake (read-only data layer), no new
infrastructure. Built solo.

## Docs

- Pilot scoping doc (exec-facing): https://docs.google.com/document/d/18CgqX4YoVNY44hkIjf6umtcVn-4q7gwkA_OvryEpXrY (tab "RTB 2.0 Dashboard")
- Technical build plan (architecture, verified queries, roadmap): https://docs.google.com/document/d/1m24kH_Fr5ZJORWvsXnMvCiwg3cd2UIWLN1Cg28YjTjk
- Replatform table mapping + gotchas: `docs/replatform-notes.md` in this repo

## Queries

| File | Feeds | Table basis |
|---|---|---|
| `queries/performance_cube.sql` | Daily/weekly Performance page — meetings, pipeline, closed-won, closed-lost by LW/TW/MTD/QTD | **New** `FLEX.SALES.FCT_CRM_OPPORTUNITY` + `FLEX.MART.DIM_EMPLOYEE_HISTORY` |
| `queries/rolled_out_units_cube.sql` | Monthly lookback page — recap vs. new, MSP, segment, team, deal type | **Old** `PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS` — no new-platform equivalent exists yet, see replatform notes |
| `queries/insights_trend_flags.sql` | Insights panel — spike/dip callouts per dimension slice vs. prior period | Old table, same as rolled-out units cube |
| `queries/insights_driver_concentration.sql` | Insights panel — "who's actually driving this number" callouts | Old table, same as rolled-out units cube |

All queries validated against live Snowflake as of 2026-07-27 — real output samples are in
each file's header comment. Thresholds (materiality floors, % change cutoffs) are marked
`-- tune this` and are starting guesses, not final.

## Superblocks wiring notes

- `{{ Component.value }}` blocks are Mustache bindings to Superblocks filter/dropdown
  components — same pattern already running in `flex-voyager`.
- `{{ Dimension.value }}` on the Rolled-Out Units Cube is a dropdown bound to a raw column
  name (`PMS`, `HUBSPOT_DEAL_TYPE`, `HUBSPOT_COMPANY_SEGMENT`, `HUBSPOT_STATIC_TEAM_NAME_DEAL`,
  `HUBSPOT_DEAL_OWNER`) — this is what makes one query drive every slice instead of building
  one query per dimension.
- Drill-down: clicking a row sets a hidden filter component to that row's value and switches
  `Dimension.value` to the next grain down (team -> rep, or MSP -> team). Same query re-fires,
  no second query needed per drill level.
- Insights panel: run `insights_trend_flags.sql` and `insights_driver_concentration.sql` on
  a schedule (daily/weekly — TBD) and bind the `callout` column directly to a text list
  component at the top of the dashboard. No separate job/service needed, it's just two more
  queries against the same tables.

## Known open items

- **Rolled-Out Units has no new-platform equivalent yet.** Ping the Flex data platform team
  (they explicitly invited this per their Notion) rather than working around it indefinitely.
- **Team filter needs a pod-to-manager mapping.** `HUBSPOT_STATIC_TEAM_NAME_DEAL` is pod-level
  (Brandon's Team, DSMB 1-5, SMB AEs 1/2), not the manager names Sham thinks in (Rory, Seba,
  Brandon, Dana).
- **Segment column choice:** use `HUBSPOT_COMPANY_SEGMENT`, not `ACCOUNT_SEGMENT` — they
  disagree significantly (see replatform notes).
- **Deal-level MSP field is dirty** on the opportunity table (~900 rows with multiple values
  jammed into one field) — use `PMS` on the rolled-out-units table instead for MSP slicing.
- **Insights thresholds are untuned guesses** — run for a week against real data before
  trusting the cutoffs; adjust based on what Sham actually finds noisy vs. useful.
