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

## 4.10. Debrief (left-nav item, not a tab — restructured 2026-08-04)

Kevin: "can we create a tab where he can just go into and learn everything that's
happening — click a segment/MSP/team button, filter by time horizon/deal type/unit type,
and get trends, wins, concerning things, and — if a team's selected — the individual
drivers behind it." Most of the backend already exists and already accepts this
dashboard's standard filter surface; this is mostly an integration + prompt task, not a
new data build.

**PLACEMENT (changed 2026-08-04)**: Debrief moves OFF the top tab bar (Deals & Units /
Pipeline / Activities / Segment × MSP / Trends & Insights / Watch List) and becomes its
own **left-sidebar entry**, alongside Dashboard/Performance/Query Audit — Kevin's framing:
it's a distinct destination for "learn everything that's happening," not one more tab
among the detail pages. Pure navigation change, no query changes.

**RESTRUCTURED INTO TWO TIERS (2026-08-04)** — Kevin, on the first shipped version (a flat
list blending a company headline with 5 individual rep bullets): "think like you're a
leader or the CEO. what do you care about more? if one rep closed a deal? no, you care
about where the whole business is going." Macro leads, always; individual drivers are a
separate, secondary section, never interleaved.

**Tier 1 — Macro Trends (always the top section, regardless of which lens/filter is
active):**
- Overall unit trend, **New vs. Recaptured split** — `ai_summary_facts.sql` Part A. Fixed
  2026-08-04: Part A used to filter to new-integrated units only, so the headline total
  silently excluded recaptured units entirely (~24% of real volume, confirmed live) — Part
  A now returns the true total plus `new_units_this/last` and `recaptured_units_this/last`
  broken out explicitly.
- **New Logo vs. Expansion mix trend** — Part E (`current_expansion_share`,
  `current_direction`, `streak_length_months` — already handles the "1-month blip vs. real
  pattern" distinction, no change needed).
- **MSP trend/concentration** — `ai_summary_facts_msp.sql` — always part of the macro
  picture, not gated behind selecting the MSP lens specifically (MSP mix is a "shape of the
  business" fact, same tier as unit/mix trends, not a micro one).
- Period-maturity check (`days_elapsed`/`days_total_in_period`, §4.5 priority 0) still
  applies here first, before any of the above gets narrated as a trend.

**Tier 2 — Individual Drivers (separate, secondary, visually de-emphasized — e.g. a
collapsed/expandable card below Macro Trends, NEVER inline bullets mixed into it):**
- Top-3 rep drivers within the current filter — `ai_summary_facts.sql` Part B — used only
  as *breadth context* for the macro headline ("concentrated in 2 reps" / "broad-based"),
  not as a per-rep bullet list of its own.
- Full per-rep detail (unit trend + win rate + streak/personal-best) — only when Team is
  the active lens — `debrief_facts_team.sql` (unchanged; deliberately has no team-level
  total of its own, so there's never two different "team total" numbers to reconcile).
- Default state should be collapsed or visually secondary (smaller card, below the fold) —
  available on demand, never competing with Macro Trends for the same visual weight.

**Dimension selector**: Segment / MSP / Team — mutually exclusive, pick one primary lens;
this narrows WHICH SLICE the macro facts are computed over (e.g. Team = Rory's Team scopes
the unit/mix trend to that team), it does not change which tiers appear. **Deal Type**
(New Logo/Expansion/Move In) and **Unit Type** (new vs. recaptured) are refinement filters
layered on top — Unit Type only applies to rolled-out-units facts, Deal Type only to
deal-grain facts. **Time horizon** (This Week/Month/Quarter) is always active.

**Prompt-layer fix, the direct cause of the flat-list bug**: wire Macro Trends and
Individual Drivers as two visually separate blocks with two separate headers (or two
separate LLM calls, whichever is cleaner in Superblocks) — never one prompt call that
dumps every available fact into a single undifferentiated bullet list. Same discipline as
the main AI Summary applies to both tiers: no named deal/account-level risk callouts,
quantified-only forward-looking flags, never let a data-hygiene artifact read as a
business signal, and — same non-negotiable rule as Shout Outs — never a bullet in either
tier that implies one teammate underperformed relative to another.

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

## 4.12. Proactive Insight Scanners — Macro Trends fast-follow layer (written down 2026-08-04)

Kevin, on the first shipped Debrief tab: "this is super basic compared to what this could
be... I want to see trends for all major MSPs (mix too), segments, teams, new logo vs
expansion, new vs recaptured, closed won vs closed lost, total rolled out units, time trends
(MoM, QoQ), and rep-level trends. I want more than just 'total units went up 10%, x rep
contributed y.'" Then, walking blind spots: net units reconciliation, account concentration,
sales cycle time trend, and deal size trend.

**The core technique, reused across every file below**: generalize the single-series
gaps-and-islands streak detector already used in `ai_summary_facts.sql` Part E
(`SIGN(value - LAG(value))` → break-group via running sum of sign changes → `COUNT` within
the latest group) by adding a `PARTITION BY <dimension>` — this scans every team/segment/MSP
at once instead of one pre-filtered slice, the same "scan everything, flag threshold-crossers"
principle `insights_trend_flags.sql` already uses, just combined with a multi-month streak
requirement for the first time.

**7 new files, all in `queries/`, all DSMB-excluded via the standard `pmc_size` join
(current live PMC total > 750 units):**

| File | What it scans | Materiality floor |
|---|---|---|
| `insights_declining_streaks.sql` | Team (A) / MSP pipeline deal count (B) / segment (C) / MSP rolled-out units (D) decline streaks | 10,000 units (team/segment), 1,000 units (MSP), 10 deals (MSP pipeline) |
| `insights_mix_shift_scanner.sql` | MSP share-of-total (A), New Logo vs. Expansion share by team (B) / segment (B-Segment), New vs. Recaptured share by team (C) / segment (C-Segment) | 2% latest share (MSP), streak-on-direction not fixed threshold (mix parts — see below) |
| `insights_daily_pace_scanner.sql` | Team (A) / segment (B) / MSP (C) daily rollout pace, trailing-7-days vs. prior-7-days | `MinDailyAvgFloor` / `MinPctDropThreshold` (validated ~59% drop threshold) |
| `insights_net_units_bridge.sql` | Company-wide (A) / segment (B) net units bridge, deactivation-rising streak (C), single-month deactivation spike (D) | segment bridge only; 15% single-month spike (D) |
| `insights_account_concentration.sql` | Top-5 PMC combined share of new+recaptured units, trended (A) + rising-concentration streak (B) | top-5 combined, not top-1 (largest single PMC is 9.6% of 413 contributing) |
| `insights_cycle_time_trend.sql` | Touch-to-close median days by segment (New Logo only), trend (A) + lengthening/shortening streak (B) | `MinDealsFloor` (validate against real monthly deal counts) |
| `insights_deal_size_trend.sql` | Avg + median deal size by segment, trend (A) + streak (B) | `MinDealsFloor`; **median is the primary trended metric**, not average — distribution is heavily right-skewed by whale deals |

**Why streak-on-direction instead of a fixed skew threshold (mix-shift, deal-size, cycle-time
files)**: checked live — MM/Ent and Strategic structurally run 60–100% Expansion share most
months (larger, established accounts), so a fixed ">65% = too skewed" band would permanently
false-alarm on them. Both directions surface instead (a mix shift isn't inherently good or
bad on its own — a sustained *move* is the signal), same reasoning applied to deal size
(shrinking isn't inherently bad, growing isn't inherently good) and cycle time (lengthening is
bad news, shortening is good news, but both are worth surfacing).

**Why week-over-week trailing windows, not single-day-vs-average, for daily pace**: rollout
data has a strong weekend rhythm (near-zero Saturdays/Sundays) — checked live, a naive
"today vs. 7-day average" false-flags every weekend. Fixed by comparing two like-for-like
7-day windows (trailing 7 days vs. the 7 days before that), which cancels the rhythm out.

**Why net units bridge matches Kevin's own reconciliation, not a re-derivation**: `Net Change
= New Integrated + Recaptured + Uplevel to Integrated − Deactivated − Downlevel to NIRO +
Remaining Net Change` (the residual/unexplained bucket) — this is the exact formula from an
existing Sigma "Integrated Units [Full Month]" table, not something invented here. Cross-
validated against `IS_INTEGRATED_TOTAL`'s own month-over-month change; reconciles within
1–4% every month (small residual attributed to this dashboard's DSMB exclusion, which the
Sigma source table likely lacks).

**The "activities dropped → expect a % pipeline decrease" idea was checked and rejected as a
quantified claim**: company-wide AE activity (calls + meetings) vs. next-month pipeline
created, 12 full months, same-month r=0.31, 1-month-lag r=0.26 — too weak and inconsistent to
support a quantified number. If this ever gets built, it must be a directional flag only
(activity meaningfully up/down, materiality-floored), never a "% decrease" figure — matches
this repo's standing finding on activity correlations elsewhere (SDR calls, AE meetings).

**Calendar-vs-BP-month bucketing bug, caught 3 more times building this layer** (on top of
every prior occurrence documented elsewhere in this doc): `insights_declining_streaks.sql`
Part B, `insights_cycle_time_trend.sql`, and `insights_deal_size_trend.sql` all first drafted
with `DATE_TRUNC('month', <date column>)` (calendar), which mislabels the last few days of a
BP month as belonging to the next one — fixed to the standard
`IFF(DAY(<col>) <= 4, DATE_TRUNC('month', <col>), DATE_TRUNC('month', DATEADD(month, 1,
<col>)))` formula in all three. **Note**: `insights_cycle_time_trend.sql`'s fix was
documented as already done in an earlier pass but had never actually been committed — the
file still had the calendar bug until the 2026-08-04 Granularity toggle pass caught and fixed
it live. If a query built off `CLOSED_AT_UTC`/`CREATED_AT_UTC` ever looks off by a
suspiciously round amount at a month boundary, check this first.

**Month/Quarter granularity toggle** — Kevin: "adding time granularity will be helpful, so if
Sham wants to see MoM or QoQ we can have all these queries adjust." Every file above except
`insights_daily_pace_scanner.sql` (inherently week-grain by design) takes a
`{{ Granularity.value }}` = `'Month'` | `'Quarter'` Superblocks parameter, using
`IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', bp_month), bp_month) AS
period` — this works because BP_MONTH is stored as a calendar-month-labeled date (e.g. "Jul
BP" = 2026-07-01, real dates Jun 5–Jul 4), so truncating to quarter directly groups the right
3 BP-month labels with zero extra logic (confirmed live: Jul/Aug/Sep BP all truncate to
2026-07-01 = BP Q3, matching Kevin's own description). Streak-scanner lookbacks were widened
from 12 to 24 months (fixed) so Quarter grain still has enough periods for a real streak;
trend-view lookbacks scale by `{{ LookbackMonths.value }} * IFF(Quarter, 3, 1)`.

**Wiring into Debrief (§4.10) Tier 1 — Macro Trends**: these scanners are the proactive layer
behind the always-on macro section — a scanner firing a flag (a real streak, a spike, a
concentration move) is what makes a bullet like "SMB team's rolled-out units have declined 3
straight months" or "Entrata's pipeline is drying up, 5 months running" appear, instead of
only ever reporting "units went up/down X% this month." Same non-negotiable narration rules
apply as the rest of Debrief: no named deal/account-level risk callouts, no bullet implying
one teammate underperformed another, and the activity-correlation rule above (directional
only, never quantified) must be respected if that scanner is ever built.

**Stage 2 — explicitly deferred, not forgotten**: generalizing
`insights_closed_lost_trend.sql` into a multi-entity scanner; an SDR activity decline streak
(`PARTITION BY sdr_segment` on `sdr_activity_to_pipeline.sql`'s `sdr_calls`); and a rep-level
decline-streak flag added to `debrief_facts_team.sql` (which already carries
`leader_streak_months`/`is_personal_best` per rep, just not a decline-streak flag yet). None
of these are difficult given the pattern above — deferred purely for sequencing.

## 4.13. NIRO tab + Strategic Value Hierarchy (written down 2026-08-04)

Kevin, building on the Macro Trends scanner layer: "maybe we should include a NIRO tab too.
this is non integrated units. this should have similar charts like which teams, reps,
segments etc, across which MSPs. and trend analysis too. then maybe an integrated vs non
integrated mix trend call out — if non-integrated units is a bigger share a few months in a
row might want to call that out bc integrated units are more valuable to us." He also gave a
value hierarchy to frame every callout going forward — captured here once so future narration
work references it instead of re-deriving it.

**New top-tab-bar page "NIRO"**, placed next to the existing "Segment × MSP" tab (same tier as
Rolled-Out Units — a drill-able detail page, not a left-nav narrative destination like
Debrief). Fed by `queries/niro_units_cube.sql`: same `{{ Dimension.value }}` slice pattern,
DSMB exclusion, and segment/team bucket mapping as `rolled_out_units_cube.sql`, plus a
Month/Quarter `{{ Granularity.value }}` toggle built in from the start.

**MSP dimension is different from every other file in this repo — read before reusing the
pattern elsewhere.** `PMS` (the field every other MSP-sliced query uses) is populated ONLY on
already-integrated properties — confirmed live, every non-integrated row has `PMS = NULL`.
Fixed via `DIM_SALES_ACCOUNTS.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES` (account-level, confirmed
1:1 join, no fan-out), the same field the comp engine's `pull_niro_units` already uses.

**AppFolio is deliberately NOT carved out of NIRO here.** The comp engine's `pull_niro_units`
excludes AppFolio-PMS accounts from NIRO entirely (treats AppFolio embed as "payment-
integrated, Yes Adjusted" for comp purposes). Asked Kevin directly whether this dashboard
should match that or show the raw number — he chose raw: AppFolio shows up as the single
largest NIRO MSP by a wide margin (~140K units, 2x+ the next biggest), and that's exactly the
kind of gap worth surfacing to Sham, not hiding. This dashboard's NIRO totals will disagree
with the comp engine's `team_niro_units` by roughly that amount — expected, not a bug.

**Two real bugs caught live before shipping, both instructive beyond this file:**
- **Stock-vs-flow at Quarter grain**: `niro_units` and `integrated_total_units` are both
  per-BP_MONTH snapshots (same class as `IS_INTEGRATED_TOTAL` elsewhere in this repo). A naive
  GROUP BY on the Quarter-truncated period summed 3 months of the same stock value into one
  bucket, inflating every Quarter number ~3x (MM/Ent showed 348K-612K/quarter vs.
  126K-188K/month — the tell-tale triple-count). Fixed with the same two-stage pattern
  `insights_net_units_bridge.sql` already uses: aggregate to real BP_MONTH grain first, THEN
  roll up to the requested period via `MAX_BY(value, BP_MONTH)`.
- **Departed-rep exclusion applied to a stock column is wrong, not conservative.**
  `rolled_out_units_cube.sql`'s departed-rep filter (drop rows whose `HUBSPOT_DEAL_OWNER` is
  inactive beyond a grace window) exists for FLOW/attribution correctness and its own header
  calls the effect "immaterial" (189 units, one legacy pod). That assumption breaks for STOCK
  totals: measured live on MM/Ent alone, the same filter would have dropped 460,172 integrated
  units and 42,108 NIRO units (14-18% of that segment's real current stock) — properties that
  are still genuinely integrated/engaged today, just originally closed by someone no longer at
  Flex. A property's current network status doesn't depend on who sold it years ago. Removed
  the filter from `niro_units_cube.sql`'s stock columns entirely — worth checking whether
  `rolled_out_units_cube.sql`'s own `integrated_total_units` column has the same latent issue
  (not yet checked, flagged here as a follow-up, not fixed in this pass since it wasn't part
  of what Kevin asked for and changing an existing shipped headline number needs its own
  sign-off).

**`queries/insights_niro_mix_trend.sql`** — same partitioned gaps-and-islands streak
technique as the other 8 scanners, applied to NIRO's share of (integrated + NIRO) total, by
segment (Part A) and team (Part B). Direction matters here, unlike the neutral
`insights_mix_shift_scanner.sql`: only a RISING NIRO share is flagged (integrated units are
the more valuable side of this mix — see the hierarchy below), same "direction matters" logic
as `insights_net_units_bridge.sql`'s churn-rising streak. Validated live: MM/Ent has a real
7-month rising NIRO-share streak (now 6.53%), House Accounts a 3-month streak (3.47%) —
confirmed stable at both the default 10,000-unit floor and a much lower 1,000-unit floor
(identical result set), and ties out exactly to `niro_units_cube.sql`'s independently-computed
share for the same segment/period.

**Strategic Value Hierarchy — narration guidance, not new hard thresholds beyond the mix-trend
scanner above.** Four axes Kevin gave, with his own supporting rationale, so any future
narration work (Debrief, AI Summary, the NIRO callout itself) references this instead of
re-deriving it:

1. **Integrated > NIRO.** Enforced by `insights_niro_mix_trend.sql` above — a sustained rising
   NIRO share is the one flag worth surfacing on this axis.
2. **New Logo / new units > Recaptured / Expansion.** Narration framing only — the data
   already exists via `ai_summary_facts.sql`'s new/recaptured split (§4.10); no new query.
3. **RealPage / Yardi / Entrata (strategic DI-footprint priority) > AppFolio (lower comp/NAR
   value) > other MSPs.** Kevin's rationale: most AppFolio volume comes in Embed-only (not
   full DI+marketing), and AppFolio's own NAR in that channel runs materially lower than the
   DI+marketing tier Yardi/RealPage/Entrata typically sit in — Flex's NAR modeling uses
   AppFolio's ~4% DI penetration as the empirical anchor for the lowest "Embed Only" curve
   (~4.5% NAR by M12) vs. ~8% for DI+Marketing; live AppFolio Embed NAR ran 3.18%→4.51% over
   Jan-Jun 2026. AppFolio is also excluded from the Q3 2026 per-unit spiffs that DO apply to
   RealPage/Yardi/Entrata — a direct, current comp-policy signal pointing the same direction.
   Colors how `insights_mix_shift_scanner.sql` Part A's MSP-share callouts and the new
   NIRO-by-MSP breakdown should read: a rising Yardi NIRO gap reads as more urgent than a
   rising AppFolio one, and AppFolio dominating the NIRO-by-MSP breakdown is an expected,
   lower-priority fact, not the day's headline.
4. **Strategic segment (higher $/account) > MM/Ent > SMB per-account, while SMB remains the
   largest by volume.** Both framings stated together, neither replacing the other — SMB's
   volume dominance is still a real, important fact on its own axis (this dashboard already
   treats SMB as materially important throughout), it's just not the same axis as
   per-account value.

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
