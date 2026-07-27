# Snowflake Replatform — table mapping and gotchas

Flex is migrating Snowflake from `PRODUCTION.*` to a new `FLEX` database (`FLEX.SALES`,
`FLEX.MART`, `FLEX.INTERMEDIATE`, `FLEX.REPORT`, `FLEX.STG_*`). Old tables stay live for
roughly 6 more months from 2026-07-16. Source of truth: the Flex data platform team's own
mapping sheet (https://docs.google.com/spreadsheets/d/14d3m7fVAgQ3hIX4JqmJzfvedem-xNF5YMFfndV5kO0c)
and Notion page (https://app.notion.com/p/getflex/FLEX-database-3524b351646a8020ba3fd3484db8628d).

## Sales / CRM domain — ready to build on now

| Old | New | Key renames |
|---|---|---|
| `PRODUCTION.SALES.FCT_SALES_OPPORTUNITIES` | `FLEX.SALES.FCT_CRM_OPPORTUNITY` | `SALES_EMPLOYEE_KEY`->`OWNER_SK`, `SDR_KEY`->`SDR_SK`, `SALES_ACCOUNT_KEY`->`CRM_ACCOUNT_SK`, `OPPORTUNITY_STAGE`->`CURRENT_STAGE`. Now unions Salesforce + HubSpot (`SOURCE_SYSTEM` column). |
| *(new)* | `FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM` | Property-level breakdown per deal (`PROPERTY_ID`, `ROLLOUT_MONTH`, `UNIT_COUNT`) — didn't exist before. |
| `PRODUCTION.SALES.FCT_SALES_ACTIVITIES` (meetings) | `FLEX.SALES.FCT_CRM_MEETING` | `SALES_EMPLOYEE_KEY`->`EMPLOYEE_SK`, `SALES_ACCOUNT_KEY`->`CRM_ACCOUNT_SK`, `ACTIVITY_TYPE`->`MEETING_TYPE`, `ACTIVITY_STATUS`->`MEETING_STATUS` |
| `PRODUCTION.SALES.FCT_SALES_TASKS` | `FLEX.SALES.FCT_CRM_TASK` | Same rename pattern |
| `PRODUCTION.SALES.DIM_SALES_ACCOUNTS` | `FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY` | Now SCD2 — filter `WHERE IS_CURRENT = TRUE` |
| `PRODUCTION.SALES.DIM_SALES_EMPLOYEES` | `FLEX.MART.DIM_EMPLOYEE_HISTORY` | Also SCD2, filter `WHERE IS_CURRENT = TRUE`. `PARENT_TEAM_NAME`->`PARENT_TEAM`. |
| `PRODUCTION.ANALYTICS.DIM_PROPERTIES_PMCS` | `FLEX.MART.DIM_PROPERTY` (+ `DIM_PROPERTY_HISTORY`) | Integrations moved to `FCT_BILLER_INTEGRATION`, marketing config to `FCT_BILLER_RESOLVED_MARKETING` |

All confirmed populated with live data as of 2026-07-27 (row counts, min/max dates checked,
not just schema presence).

## Confirmed gap — do not migrate this piece yet

`PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS` (rollout/recap/tier/segment/deal-type flags)
has no MART/REPORT-level replacement. `FLEX.STG_FLEX.STG_PARTNER_HUB__PROPERTY_BP_MONTH_STATS_CDC`
exists but is a bare CDC mirror missing `IS_NEW_ROLLOUT`, `IS_RECAPTURED_*`, `INTEGRATION_TYPE`,
`PMS`, `CURRENT_TIER`, `HUBSPOT_COMPANY_SEGMENT`, `HUBSPOT_DEAL_TYPE`,
`HUBSPOT_STATIC_TEAM_NAME_DEAL`, `ROLLED_OUT_UNITS_MOM_CHANGE`, `IS_INTEGRATED_TOTAL` — every
flag this dashboard's rolled-out-units side depends on. Stay on the old table. The platform
team's Notion explicitly invites requests for tables not yet migrated — worth pinging them.

## Naming convention (from platform team's Notion)

- Schema layers: `mart` (analyst-facing, join here first) -> `report` (pre-aggregated) ->
  `dashboard` (pre-joined for dashboards, not seen live yet) -> `staging` (raw CDC, avoid
  querying directly except for confirmed gaps like above).
- All table and column names now singular. IDs: `<entity>_id`. Timestamps: `*_at_utc`.
  Booleans: `is_*`/`has_*`.
- SCD2 history tables (`*_history`): `WHERE IS_CURRENT = TRUE` for current snapshot, or join
  on `<event_ts> BETWEEN VALID_FROM_UTC AND VALID_TO_UTC` for point-in-time accuracy.
- New `FLEX.*` tables are NOT pre-filtered to rent/Flex-only data unless the name explicitly
  says `rent_customer` (unlike many old `PRODUCTION.*` tables) — check filters, don't assume.
- Flex1-era historical data may have discrepancies post-migration — a known limitation per
  the platform team, not necessarily a query bug.
- Dagster (https://getflex.dagster.cloud/prod/home, SSO) shows lineage, last-refresh time,
  and model health per table.
