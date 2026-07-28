-- AI Summary Facts -- feeds the "Worth Knowing Right Now" AI-generated summary. Per Kevin:
-- replace the static Watch List teaser with a summary that reflects WHATEVER filters are
-- currently selected (period + team/segment/MSP/deal type), not a fixed set of deal-level
-- callouts -- "if we filter on this month and appfolio and strategic segment, the summary
-- reflects... driven by x rep or y deal."
--
-- THIS QUERY DOES NOT WRITE THE SUMMARY. It only gathers the facts an LLM call then narrates.
-- Keep those two steps separate -- this query returns numbers, a downstream LLM step (see
-- docs/superblocks-setup.md's AI Summary section) turns numbers into prose. Don't ask an LLM
-- to also compute the numbers itself -- that's how you get confidently wrong math.
--
-- Same base/filters as rolled_out_units_cube.sql (DSMB-excluded, segment_bucket/team_bucket/
-- PMS/HUBSPOT_DEAL_TYPE all filterable, same escaping caveats) -- this is deliberately the
-- SAME filter surface, so the AI summary always reflects exactly what's on screen, not a
-- separate parallel set of filters that could drift out of sync.
--
-- Part A: headline this-vs-last for the current filter combination.
-- Part B: top 3 drivers (reps) within that same filter combination, with each one's % of the
-- total -- this is what lets the LLM say "driven by X rep" instead of guessing.
-- Validated live 2026-07-28, Strategic segment + AppFolio: this_period 297 vs last_period 18
-- units (real, dramatic swing) -- Part B shows it's driven by Ariel Kurek (175, 59%) and
-- Jennette Sanchez (122, 41%), a 2-rep concentration worth naming explicitly, not just "the
-- Strategic team is up."

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.IS_NEW_INTEGRATED
      {{#Team.value}}     AND team_bucket = '{{Team.value}}'          {{/Team.value}}
      {{#Segment.value}}  AND segment_bucket = '{{Segment.value}}'   {{/Segment.value}}
      {{#Msp.value}}      AND PMS = '{{Msp.value}}'                  {{/Msp.value}}
      {{#DealType.value}} AND HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
)
-- Part A: headline
SELECT
    SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0)) AS this_period_units,
    SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), PROPERTY_UNIT_COUNT, 0)) AS last_period_units,
    DIV0(
        SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0))
        - SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), PROPERTY_UNIT_COUNT, 0)),
        SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), PROPERTY_UNIT_COUNT, 0))
    ) AS pct_change
FROM base
WHERE BP_MONTH IN ((SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS),
                   DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)));

-- Part B: top 3 drivers within the SAME filter combination, this period only.
-- Separate statement -- needs its own copy of the pmc_size/base CTEs, Snowflake doesn't
-- share a WITH clause across two semicolon-delimited statements (caught while validating --
-- first draft referenced `base` here and failed with "Object 'BASE' does not exist").
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.IS_NEW_INTEGRATED
      {{#Team.value}}     AND team_bucket = '{{Team.value}}'          {{/Team.value}}
      {{#Segment.value}}  AND segment_bucket = '{{Segment.value}}'   {{/Segment.value}}
      {{#Msp.value}}      AND PMS = '{{Msp.value}}'                  {{/Msp.value}}
      {{#DealType.value}} AND HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
)
SELECT
    HUBSPOT_DEAL_OWNER AS rep,
    SUM(PROPERTY_UNIT_COUNT) AS units,
    DIV0(SUM(PROPERTY_UNIT_COUNT), SUM(SUM(PROPERTY_UNIT_COUNT)) OVER ()) AS share_of_total
FROM base
WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
  AND HUBSPOT_DEAL_OWNER IS NOT NULL
GROUP BY 1
ORDER BY 2 DESC
LIMIT 3;
