# Superblocks Setup — RTB 2.0

Step-by-step for wiring the `queries/*.sql` files into a real Superblocks app. Written so
you can follow it without re-reading every query file first — but the queries themselves
are the source of truth if anything here goes stale.

## 0. One-time setup

1. **Datasource**: add a Snowflake datasource pointed at `getflex-prod`, warehouse
   `OPERATIONS_WH`. Use a read-only role (`OPERATIONS` or a dedicated Superblocks service
   role if IT wants one) — nothing in this repo writes data, no query should ever run under a
   role with write access.
2. **Paste queries as-is.** Every file in `queries/` is a complete, standalone SQL statement
   (or two, separated by a blank line + comment — see below). Paste directly into a
   Superblocks SQL step; don't reformat.
3. **Files with two SELECT statements** (`performance_cube.sql`, `insights_closed_lost_trend.sql`,
   `insights_stage_velocity.sql`) need **two separate Superblocks query steps**, one per
   SELECT — Superblocks runs one statement per step. Split at the `-- Part A` / `-- Part B`
   comment markers.

## 1. THE open item — apostrophe escaping (verify before wiring anything else)

Every value filter in this repo (`{{Team.value}}`, `{{Rep.value}}`, `{{Segment.value}}`, etc.)
is written as Mustache string interpolation. Confirmed live: real values contain apostrophes
("Brandon's Team", "Cory's Team") and `= '{{Team.value}}'` breaks with a SQL syntax error the
moment someone picks one of those values from a dropdown.

**Before wiring a single filter component, check Superblocks' Snowflake connector docs for
named/positional bind parameters** (most SQL connectors in low-code tools support something
like `:paramName` or a "parameterized" toggle that lets the driver escape values instead of
raw string substitution). If that exists, use it for every value filter below — it's the
correct fix and makes this whole section moot.

**If Superblocks only offers Mustache-style substitution:** add a transform to each dropdown/
filter component that doubles embedded apostrophes before the value reaches the query —
`value.replace(/'/g, "''")` — confirmed live that `'Brandon''s Team'` is valid SQL and resolves
correctly. Apply this to every component listed as a "Team" or "Rep" filter below; MSP,
Segment, and Deal Type values don't currently contain apostrophes but doubling is harmless if
applied everywhere.

**Do not apply this to `{{ Dimension.value }}` in `rolled_out_units_cube.sql`** (or `{{
Stage.value }}` in `insights_stage_velocity.sql`) — those select a raw column/stage name, not a
value, and must come from a constrained dropdown (exact allowed values below), never free text.

## 2. Global filter components (build once, reuse across pages)

These are the same handful of components referenced by `{{ X.value }}` across almost every
query. Build them once at the top of the app (or per-page if Superblocks scopes components to
a page) and bind every query below to the same instances — don't create a new "Team" dropdown
per page, or filters will drift out of sync between pages.

| Component | Type | Options | Used by |
|---|---|---|---|
| `Team` | Dropdown, single-select, clearable | `HUBSPOT_STATIC_TEAM_NAME_DEAL` distinct values (old-table queries) — confirmed list includes `Brandon's Team`, `Cory's Team`, `SMB Account Executives 1`, `SMB Account Executives 2`, `DSMB 1-5`, etc. **Note**: `insights_closed_lost_trend.sql` and `insights_stage_velocity.sql`/`opportunity_drilldown.sql` filter on `STATIC_TEAM_NAME` (new table) instead — same concept, values overlap but aren't identical strings; may need two Team components if you mix old- and new-table queries on one page. | performance_cube, rolled_out_units_cube, insights_trend_flags, insights_mix_shift, insights_closed_lost_trend, opportunity_drilldown, rep_leaderboard, watchlist_large_deals_at_risk, units_closed_forecast_bridge, insights_activity_correlation (set via drill-down click, not a manual dropdown — see §4) |
| `Segment` | Dropdown, clearable | `HUBSPOT_COMPANY_SEGMENT` distinct values | rolled_out_units_cube, insights_trend_flags, insights_driver_concentration. **Do not** build a Segment filter for `insights_stage_velocity.sql` from this same field — that query computes its own SMB/DSMB/Strategic-MM bucket internally; its `{{Segment.value}}` expects exactly one of those three bucket names, not a raw `HUBSPOT_COMPANY_SEGMENT` value. |
| `Msp` | Dropdown, clearable | `PMS` distinct values (`Yardi`, `Appfolio`, `RealPage`, `Entrata`, `ResMan`, `Rentmanager`, `Aptexx`) | performance_cube, rolled_out_units_cube, insights_driver_concentration |
| `DealType` | Dropdown, clearable | For old-table queries: `HUBSPOT_DEAL_TYPE` values. For new-table queries (`opportunity_drilldown.sql`, `performance_cube.sql`): `OPPORTUNITY_TYPE` values — confirmed set includes `New Logo`, `Expansion`, `New Vertical`, `Move In`, `Uplevel`, `Uplevel: Silver to Platinum`, `Uplevel to Integrated`, `Product Partnership`, `MSP`, `ILS`, `Add On`. Same two-taxonomy note as Team above. | performance_cube, rolled_out_units_cube, opportunity_drilldown |
| `Rep` | Dropdown or set via drill-down click | `HUBSPOT_DEAL_OWNER` (old table) or employee `FULL_NAME` (new table) | rolled_out_units_cube, opportunity_drilldown |
| `LookbackMonths` | Number input, **default required, cannot be empty** | integer, e.g. default `6` | rolled_out_units_cube, insights_mix_shift, insights_stage_velocity, insights_closed_lost_trend, opportunity_drilldown, units_closed_forecast_bridge. An empty value here is a SQL syntax error (`DATEADD(month, -, ...)`), not a harmless no-filter — set the default on the component itself, don't rely on the query to handle blank. |
| `Granularity` | Toggle: Week / Month / Quarter | — | performance_cube |
| `Dimension` | Dropdown, **constrained to exactly 5 options, never free text** | `PMS`, `HUBSPOT_DEAL_TYPE`, `HUBSPOT_COMPANY_SEGMENT`, `HUBSPOT_STATIC_TEAM_NAME_DEAL`, `HUBSPOT_DEAL_OWNER` | rolled_out_units_cube (drives which column becomes the row grouping) |
| `Stage` | Dropdown, clearable, constrained | `Qualification`, `Discovery`, `Building Value`, `Negotiation` | insights_stage_velocity |
| `BpMonth` | Date picker or set via drill-down click | any BP month | opportunity_drilldown |
| `SizeFloor` | Number input, default `100` | integer | watchlist_large_deals_at_risk |
| `PodName` | Dropdown, constrained | `Brandon's Team`, `SMB Account Executives 1`, `SMB Account Executives 2` (Dana's and Hans's pod names still unconfirmed — don't add placeholder guesses to this list) | oneonone_prep (paused, not blocking) |

## 3. Build order (matches README priority)

Build and smoke-test each page before moving to the next — every query here has already been
validated against live Snowflake, so if something breaks in Superblocks it's almost always the
wiring (component binding, escaping), not the SQL.

1. **Performance page** — `performance_cube.sql` (2 query steps: main + Meetings), bound to
   `Team`/`Msp`/`DealType`/`Segment`/`Granularity`.
2. **Rolled-Out Units page** — `rolled_out_units_cube.sql`, bound to `Dimension` (the row
   grouping) plus all 5 filters. Add `Msp` as an optional second "compare by" dimension for the
   Team x MSP matrix view (see README's UI pattern note) — same query, group by two columns
   instead of one when a second dimension is picked.
3. **Insights panel** (teaser: top 2-3 callouts inline; full tab groups by type) —
   `insights_trend_flags.sql`, `insights_driver_concentration.sql`,
   `insights_activity_correlation.sql`, `insights_closed_lost_trend.sql`,
   `insights_stage_velocity.sql`, `insights_mix_shift.sql`. Run these on a schedule (daily is
   fine to start) rather than on every page load — they're heavier scans.
4. **Watch List tab** — `watchlist_large_deals_at_risk.sql`, grouped by Deal Risk / Team
   Trends per the README's role-scoping note (team/deal grain only, never a standalone rep flag).
5. **Opportunity drill-down** — `opportunity_drilldown.sql`, wired as the terminal step of
   every drill chain (see §4).
6. **Rep leaderboard** — `rep_leaderboard.sql`, on a separate tab/modal reachable from the
   team views, not a default-visible panel (see file header for why).
7. **Forecast bridge** — `units_closed_forecast_bridge.sql`, forward-looking context strip.

## 4. Drill-down click wiring

Same mechanic throughout, already used in `insights_activity_correlation.sql`'s Part
A→Part B pattern:

- Clicking a row/bar sets the relevant filter component's value (e.g. clicking "Strategic
  Team" in a Team-grouped chart sets `Team.value = "Strategic Team"`) and the SAME query re-
  fires with that filter now populated — no new query per drill level.
- The bottom of every unit-based drill chain should route into `opportunity_drilldown.sql`
  with whatever filters are already active carried over (Rep/Team/BpMonth/DealType) — that's
  what turns "here's a number" into "here are the actual deals," per Kevin's ask.
- For `insights_activity_correlation.sql` specifically: Part A's team-level row click sets
  `Team.value`, which Part B (rep-level breakdown) is already filtered on directly — no
  intermediate step needed.

## 5. Known landmines (see README's full gotchas list for the complete set)

- Two different "Team" taxonomies exist across old-table (`HUBSPOT_STATIC_TEAM_NAME_DEAL`)
  and new-table (`STATIC_TEAM_NAME`) queries — don't assume one Team dropdown's options are
  valid for both without checking.
- `insights_stage_velocity.sql`'s `Segment` filter expects `SMB`/`DSMB`/`Strategic/MM`
  (its own computed bucket), not a raw `HUBSPOT_COMPANY_SEGMENT` value — a different
  component than the global `Segment` dropdown above.
- Segment cuts on new-table queries are unreliable (~69% "Unknown" on closed-won) — don't
  offer a Segment filter on anything that queries `FCT_CRM_OPPORTUNITY` directly unless it's
  the computed bucket in `insights_stage_velocity.sql`.
