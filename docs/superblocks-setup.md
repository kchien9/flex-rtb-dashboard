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
| `Segment` | Dropdown, clearable | **Updated 2026-07-28**: `rolled_out_units_cube.sql`'s `{{Segment.value}}` now filters on the validated `segment_bucket` column, options are exactly `Strategic`, `MM/Ent`, `SMB`, `House Accounts`, `Not Set` — NOT `HUBSPOT_COMPANY_SEGMENT` raw values anymore (that field was confirmed unreliable, see README). `insights_trend_flags.sql` / `insights_driver_concentration.sql` still use raw `HUBSPOT_COMPANY_SEGMENT` — a different component/options list, don't share the dropdown across both. `insights_stage_velocity.sql`'s `{{Segment.value}}` is a third, separate bucket (`SMB`/`DSMB`/`Strategic/MM`, computed differently, includes DSMB) — three different "Segment" concepts across this repo, do not use one dropdown's options for another. |
| `Msp` | Dropdown, clearable | `PMS` distinct values (`Yardi`, `Appfolio`, `RealPage`, `Entrata`, `ResMan`, `Rentmanager`, `Aptexx`) | performance_cube, rolled_out_units_cube, insights_driver_concentration |
| `DealType` | Dropdown, clearable | For old-table queries: `HUBSPOT_DEAL_TYPE` values. For new-table queries (`opportunity_drilldown.sql`, `performance_cube.sql`): `OPPORTUNITY_TYPE` values — confirmed set includes `New Logo`, `Expansion`, `New Vertical`, `Move In`, `Uplevel`, `Uplevel: Silver to Platinum`, `Uplevel to Integrated`, `Product Partnership`, `MSP`, `ILS`, `Add On`. Same two-taxonomy note as Team above. | performance_cube, rolled_out_units_cube, opportunity_drilldown |
| `Rep` | Dropdown or set via drill-down click | `HUBSPOT_DEAL_OWNER` (old table) or employee `FULL_NAME` (new table) | rolled_out_units_cube, opportunity_drilldown |
| `LookbackMonths` | Number input, **default required, cannot be empty** | integer, e.g. default `6` | rolled_out_units_cube, insights_mix_shift, insights_stage_velocity, insights_closed_lost_trend, opportunity_drilldown, units_closed_forecast_bridge. An empty value here is a SQL syntax error (`DATEADD(month, -, ...)`), not a harmless no-filter — set the default on the component itself, don't rely on the query to handle blank. |
| `Granularity` | Toggle: Week / Month / Quarter | — | performance_cube |
| `Dimension` | Dropdown, **constrained to exactly 5 options, never free text** | `PMS`, `HUBSPOT_DEAL_TYPE`, `segment_bucket`, `HUBSPOT_STATIC_TEAM_NAME_DEAL`, `HUBSPOT_DEAL_OWNER` (updated 2026-07-28 — `segment_bucket` replaced `HUBSPOT_COMPANY_SEGMENT`) | rolled_out_units_cube (drives which column becomes the row grouping) |
| `Stage` | Dropdown, clearable, constrained | `Qualification`, `Discovery`, `Building Value`, `Negotiation` | insights_stage_velocity |
| `BpMonth` | Date picker or set via drill-down click | any BP month | opportunity_drilldown |
| `SizeFloor` | Number input, default `100` | integer | watchlist_large_deals_at_risk |
| `PodName` | Dropdown, constrained | `Brandon's Team`, `SMB Account Executives 1`, `SMB Account Executives 2` (Dana's and Hans's pod names still unconfirmed — don't add placeholder guesses to this list) | oneonone_prep (paused, not blocking) |
| `GraceMonths` | Number input, **default required, cannot be empty** | integer, default `2` — departed-rep grace period (see README's "no inactive/wrong-team reps" gotcha) | rep_leaderboard, rep_by_msp, activity_vs_outcome_by_rep, activity_cube, closed_won_by_rep, full_funnel_by_segment, insights_activity_to_outcome, opportunity_drilldown, insights_stage_velocity, insights_activity_correlation, rolled_out_units_cube |

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

## 4.5. AI Summary — scope and priority (referenced by `ai_summary_facts.sql`, written down 2026-07-29)

**Sham's actual driving question, in his own frame (Kevin, 2026-07-29): "are things going well
— why? or are things slipping — why? Those are the driving questions behind this dashboard for
him. If certain deals get snagged, he doesn't need to know — that's not his job, maybe that's
the AE managers' job (who report to Sham). He's more big picture since he oversees the whole
sales org."** Every decision below follows from this. This is a summary FOR the person who
oversees Brandon/Rory/Sebastian/Dana, not a summary for one of them.

**EVERYTHING HERE IS BP-MONTH (AND BP-QUARTER WHERE QUARTERS APPLY), NEVER CALENDAR** — Kevin
asked directly (2026-08-04) whether the AI summary layer is BP-aware; answer, checked file by
file: `ai_summary_facts.sql`, `mtr_bullets.sql`, `performance_cube.sql`,
`activities_by_segment.sql`, `pipeline_by_stage.sql`, `closed_lost_analysis.sql` (and every
other file with a `current_bp`/`bp_month_label` CTE) all compute "this month" as the 5th of the
prior calendar month through the 4th of this one, and "this quarter" (where a Quarter toggle
exists) the same way over 3 consecutive BP months — never a raw calendar month/quarter. This is
a real, load-bearing distinction: on 2026-08-04 the current BP month (Jul 5–Aug 4) is fully
elapsed (confirmed live: 31 of 31 days), while the current CALENDAR month (Aug 1–4) is only 4
days old with 2 of those a weekend — a query built on calendar boundaries would show a tiny,
noisy partial slice on the exact same day one of these BP-based files shows a complete, mature
period. If a widget's numbers don't match what these files would produce, it isn't running one
of them — see the "Funnel Diagnosis" incident below.

**PERIOD-ELAPSED AWARENESS, REQUIRED IN THE PROMPT (added 2026-08-04)** — being BP-aware in the
SQL isn't sufficient on its own; the LLM narration step must also be told explicitly how mature
the period is, or it can still overstate a real-but-still-forming number. `ai_summary_facts.sql`
Part A now returns `bp_period_start`, `bp_period_end`, `days_elapsed`, `days_total_in_period` —
the system prompt MUST check `days_elapsed` vs. `days_total_in_period` before calling anything a
trend, a collapse, or a drop, and if the period is meaningfully incomplete, say so explicitly
("N days into this BP month") rather than comparing it 1:1 against a fully-elapsed prior period
as if they were equally mature.

**INCIDENT: "Funnel Diagnosis" widget (caught by Kevin, 2026-08-04)** — a widget by this name
showed a multi-metric "traces back to" causal chain (Closed Won ← Pipeline Created ← AE
Meetings ← SDR Calls) narrating a "complete collapse." Confirmed by exact number matching
against a raw query: it was comparing calendar Aug 1–4 against calendar Jul 1–4 (a 4-day MTD-
vs-MTD pair, 2 of those days a weekend) — NOT any BP-month boundary, and NOT any file in this
repo. It also reintroduced the exact causal-chain framing `full_funnel_by_segment.sql` was
deprecated for (see §4.1/that file's header — Kevin: "remove the whole table bc we cannot show
this causal chain at all"). **Do not rewire or fix this widget in place — replace it with
`ai_summary_facts.sql` Part D** (funnel lag, already BP-aware, already forbids the causal-chain
framing per this section) or remove it. If a similarly-named widget reappears, verify its exact
bound query against Superblocks before trusting its numbers — this is the same "Superblocks
isn't running our validated query" pattern that has recurred repeatedly throughout this build.

**Facts available** (`ai_summary_facts.sql`, same filter surface as the page it sits on):
- Part A — headline this-vs-last, whatever's currently filtered, plus `days_elapsed`/
  `days_total_in_period` (see above).
- Part B — top 3 rep drivers within that filter, with % of total (is the move broad-based or
  1-2 people carrying it).
- Part C — biggest single deal this period + its share of the scope total (is a big number one
  whale deal or real breadth).
- Part D — funnel lag (pipeline created 1-2 periods ago vs. closed-won this period).
- Part E — Expansion-share mix trend, with streak length (a 1-month blip vs. a real multi-month
  pattern — see the file's header, this already burned once: a single-month reversal was
  initially at risk of being described as "trending toward Expansion for months").
- Part F — calls/meetings trend (added 2026-07-29) — the activity leading indicator for a
  future unit move, not just a description of the past.
- Watch List (`watchlist_large_deals_at_risk.sql`) — deal-level risk detail. NOT one of the
  "facts" this summary narrates from in detail — see below.

**Priority order for the narration (top of the summary to bottom):**
0. **Check period maturity before saying anything else.** If `days_elapsed` is meaningfully
   less than `days_total_in_period`, the headline number is a partial read — state that plainly
   ("N days into this BP month") instead of narrating it as a finished comparison. This check
   comes before picking an explanatory fact; a still-forming number doesn't need one yet.
1. **The headline direction + the ONE explanatory fact that actually explains it.** Pick
   whichever of Part B (concentration), Part E (mix shift), or Part F (activity leading
   indicator) best explains Part A's move — don't stack all three if only one is actually the
   story. "Units are down 18% this month, driven almost entirely by a 47% drop in Expansion
   share" beats a sentence that also drags in an unrelated rep-concentration stat that isn't
   the real explanation.
2. **Breadth check** — is this one account/rep or a broad pattern (Part B/C answer this).
   Broad-based moves are more org-level-relevant than a single account's fluke; say so
   explicitly either way.
3. **Forward-looking flag, QUANTIFIED ONLY, never deal-level** — "N deals worth $X units are
   flagged at risk this period" is a fine, org-relevant closing line (it tells Sham the
   *category* exists and roughly how big). Naming the specific deal, account, or failure reason
   ("BH Management's July BP Implementation, marked Failed to Rollout due to a duplicate
   property") does NOT belong here — that's exactly the "certain deal got snagged" detail
   that's an AE manager's job to know, not Sham's. That level of detail lives on the Watch List
   tab where a manager drills in, not in the headline summary. If the LLM prompt currently
   passes individual Watch List rows to the model at all, stop passing them here -- pass only
   an aggregate count/sum.
4. **Never let a data-hygiene artifact read as a business signal.** A "Failed to Roll Out"
   reason of "duplicate property already active" is an operational data-quality issue, not a
   sales-execution one — if Watch List detail ever does surface in a summary elsewhere, gate
   out administrative failure reasons from ever being cited as if they were a customer/deal
   risk. (Applies to Watch List's own display too, not just this summary — consider visually
   distinguishing "administrative/data" flags from "real deal risk" flags there.)

**What this means concretely for the prompt/LLM layer**: the system prompt should say something
like "You are summarizing sales performance for the VP who oversees the whole org, not one
team. Never name an individual deal, account, or rep-level failure reason. You may cite a rep
by name ONLY as an explanation for a broad trend (Part B), never as a standalone callout. Close
with a single quantified at-risk-pipeline line if material, with no deal specifics." This is a
presentation-layer instruction, not something `ai_summary_facts.sql` enforces — the query
returns the facts, the prompt is responsible for scope discipline.

**Style**: bullets, plain language, no unexplained jargon — see §4.11, applies here too.

## 4.6. Shout Outs / Celebrations (referenced by `shout_outs_facts.sql`, written down 2026-07-30)

Kevin: "can we create a 'shout outs/celebrations' section? basically in the performance tab
maybe above manager pods — some ai generated call outs for high performance... maybe actually
do one message — and call out 1 person per team. Then sham can copy paste and drop into our
org slack thread if he wants."

**Placement**: Performance tab, above the manager pods — one combined block, not four separate
widgets.

**Output shape**: ONE Slack-ready message, one line per team (Brandon's/Rory's/Sebastian's/
Dana's, 4 lines total), each featuring exactly one rep. Give Sham a "copy" affordance on the
whole block.

**Facts available** (`shout_outs_facts.sql`): per candidate rep — `leader_streak_months`,
`is_personal_best` (vs. their own trailing 5 months), `this_month_units`,
`new_logo_deals_this_month`. Not every rep on a team is a candidate — the query already filters
to only those with a genuinely notable fact this period.

**NON-NEGOTIABLE FRAMING RULE, verbatim from Kevin**: "do not ever shout out one person by
putting down another. only focus on positive framing — big wins, positive trends, etc." The
system prompt must say something like: "For each team, pick ONE featured rep from the provided
candidates and write one celebratory sentence about what THEY achieved. Never mention, compare
to, rank against, or imply anything about a teammate's performance — no 'beat everyone,' no
'unlike last month,' no comparative language at all. If a team has zero candidates, skip that
team's line entirely rather than inventing a reason to feature someone."

**Selection guidance for the LLM** (not enforced in SQL — "most compelling" is a narrative
judgment): prefer the fact with the most concrete, specific number — a multi-month streak beats
a 1-month streak; a personal best is more specific than a generic good month; a high new-logo
count is a fine substitute when neither of the other two is notable.

**Style**: bullets, plain language, no unexplained jargon — see §4.11, applies here too.

## 4.7. Trend Team button removal (2026-07-30)

Kevin: "can we remove the trend team button and when you click the pod the chart just appears
above the table." `team_rep_units_trend.sql` already provides the per-rep monthly line-chart
data for a pod (unchanged) — this is a pure UI wiring change, no new query. Remove the separate
"Trend Team" button; wire the existing chart component to appear above the roster table
whenever a manager pod is clicked, using the same `Team.value` the pod click already sets.

## 4.8. Possible Departures removed (2026-07-30)

Kevin: "possible departures lets just remove. they know who departed." Remove the "Possible
Departures / Reassignments" section from the Coaching tab entirely. `possible_departures.sql`
is marked DEPRECATED in its own header — delete the file once this section is confirmed removed
from Superblocks.

## 4.9. Activities tab, with SDRs (new tab, written down 2026-07-31)

Kevin: "we need to layer in sdrs now. and see how sdr activities leads to pipeline —
where should that go?" There was no dedicated Activities tab before this — the activity
queries existed but weren't assigned a named tab in the build order. This tab is that
home, and it's also where SDR activity gets its first real appearance in this dashboard.

**Real bug found and fixed getting here**: `activities_by_segment.sql`'s own header used
to claim SDR activity was already included ("whoever logged them, SDR or AE alike"). It
wasn't — the team-mapping CASE only recognized AE pod names, so every SDR employee
resolved to a NULL bucket and was silently dropped by the join filter. Fixed by mapping
the 3 real SDR pods (Strategic/MM+Enterprise/SMB SDRs — segment-scoped only, no
team-level SDR split exists) and adding a `role` column (`AE`/`SDR`).

**Placement and content**:
- `activities_by_segment.sql` (now role-split) and `activities_by_team.sql` (AE-only,
  unchanged — correctly scoped already, SDR has no team-level split to show) — bind
  charts so AE and SDR bars are visually distinct, never stacked into one undifferentiated
  total (same "show separately" rule as New vs. Recaptured units elsewhere in this repo).
- `sdr_activity_to_pipeline.sql` — SDR calls trended against New Logo pipeline created, by
  segment. **Show `sdr_headcount` next to the calls number, always** — Strategic SDRs is
  currently ONE person (Louis Trujillo), so that segment's line is literally one person's
  day-to-day activity, not a team signal. A viewer who doesn't see the headcount will
  misread his PTO as "Strategic SDR activity collapsed."
- **Label this a correlation, not attribution**, in the UI copy itself, not just this doc —
  re-validated live that only ~11% of New Logo opportunities resolve to a real named SDR,
  so this shows SDR-pod activity next to AE-segment pipeline, never a claim that a specific
  SDR sourced a specific deal.
- No SDR quota/target field exists anywhere in this repo (confirmed via full-repo grep) —
  this tab shows activity volume and trend only. Don't add a progress-bar-to-target
  treatment; there's no target to show progress against yet.

## 4.10. Debrief tab (new tab, written down 2026-07-31)

Kevin: "can we create a tab where he can just go into and learn everything that's
happening — click a segment/MSP/team button, filter by time horizon/deal type/unit type,
and get trends, wins, concerning things, and — if a team's selected — the individual
drivers behind it." Confirmed buildable — most of the backend already exists and already
accepts this dashboard's standard filter surface; this is mostly an integration + prompt
task, not a new data build.

**Dimension selector**: Segment / MSP / Team — mutually exclusive, pick one primary lens.
**Deal Type** (New Logo/Expansion/Move In) and **Unit Type** (new vs. recaptured) are
refinement filters layered on top, not additional primary lenses — Unit Type only applies
to rolled-out-units facts, Deal Type only to deal-grain facts, so grey one out (or hide it)
depending which primary lens and which underlying facts are active. **Time horizon** (This
Week/Month/Quarter) is always active, same period pattern as every other tab.

**Dispatch logic** (Superblocks-side — no new query needed for this part):
- Segment or Team selected → `ai_summary_facts.sql` (all parts) for the headline, plus (Team
  only) `debrief_facts_team.sql` for individual drivers.
- MSP selected → `ai_summary_facts_msp.sql`.
- Deal Type / Unit Type pass straight through as the `{{ DealType.value }}` / (new) unit-type
  filter params these queries already accept — no new plumbing.

**New file `debrief_facts_team.sql`** — the one real gap: per-rep unit trend + win rate +
streak/personal-best facts, pre-filtered to one team, so the LLM narrates from one coherent
fact set instead of stitching 3 separate query outputs together itself. Deliberately does
NOT compute a team-level total (that's `ai_summary_facts.sql`'s job already) — don't let the
Debrief prompt receive two different "team total" numbers to reconcile.

**Same discipline as the main AI Summary applies here too**: no named deal/account-level
risk callouts, quantified-only forward-looking flags, never let a data-hygiene artifact read
as a business signal, and — same non-negotiable rule as Shout Outs — never a Debrief bullet
that implies one teammate underperformed relative to another.

## 4.11. Punchy, accessible AI summaries — style rule for ALL narration (written down 2026-07-31)

Kevin: "can we make it such that anyone from outside the organization can understand what
it's saying? I think we need to focus on punchy impactful bullets rather than paragraphs."
This is a system-prompt change, not a SQL change — apply it to every LLM narration step in
this dashboard: the main AI Summary (§4.5), MTR Bullets (`mtr_bullets.sql`), Shout Outs
(§4.6), and the new Debrief tab (§4.10). Write it once here, reference it from each:

- **Bullets, never paragraphs** — one line per point.
- **No unexplained internal jargon** — "BP month," "NAR," "DSMB," "MSP" either get spelled
  out inline on first use or get replaced with plain English. Someone outside Flex who's
  never seen this dashboard should be able to follow every line without a glossary.
- **Short, declarative sentences.** Cut qualifiers that don't change the decision.

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
- **Every rep-listing query now excludes departed/wrong-team reps by construction** (fixed
  2026-07-29, see README's data-quality gotchas for the full writeup) — don't re-introduce a
  raw `DIM_EMPLOYEE_HISTORY` join if you add a new rep-level query, use the `team_map` CTE
  pattern from `activity_vs_outcome_by_rep.sql` instead. `GraceMonths` must have a default
  (2) set on the component — an empty value is a SQL syntax error, same as `LookbackMonths`.
- `open_opportunities_by_segment.sql`'s staleness filter now uses real Task/Meeting activity
  instead of `UPDATED_AT_UTC` (proven to be an automated-sync timestamp, not a human-touched
  signal) — this is a much stricter filter and drops the "fresh" pipeline number a lot (2.6M
  vs. the old 14.8M). Also surfaced a separate, unresolved finding: `STATIC_TEAM_NAME`
  (team attribution) on OPEN deals correlates almost perfectly with deal age — unattributed
  ("Not Set") deals are nearly all <2 months old, attributed deals are nearly all >400 days
  old — meaning segment-level cuts of open pipeline may not be a meaningful view at all. Flagged
  to Kevin, not yet resolved.
- `rolled_out_units_cube.sql`'s "Rolled-Out Units, by Segment" card must bind to
  `new_integrated_units` (the FLOW metric, one BP month), never `integrated_total_units` (the
  STOCK metric, cumulative network total) — confirmed live a Superblocks card was showing the
  stock number (MM/Ent 3.5M) under a "Rolled-Out Units" label; real rolled-out-this-month for
  MM/Ent is ~27-62K. Same stock-vs-flow bug class as the earlier 30M-unit incident, different
  flavor (wrong column, not summed across months this time).
