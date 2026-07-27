-- Insights Engine, Part 2: Driver concentration ("who is actually driving this number")
-- Sham's own example: "Brandon's team avg is driven by Umar's units - he's having a great
-- month." This flags when one child (rep) accounts for a disproportionate share of its
-- parent's (team's) total -- i.e. the parent number isn't broad-based, it's one person.
--
-- Validated against live Snowflake 2026-07-27. Real output included some 100%-share rows
-- that are NOT meaningful callouts -- they're pods with only one active rep this month, so
-- "driving" is trivially true. Added MIN_CONTRIBUTORS filter below to exclude those; re-verify
-- once wired in, this was patched after the initial test run, not re-tested live yet.
--
-- FILTER ESCAPING -- {{ Segment.value }}/{{ Msp.value }} below narrow the scan. Same
-- apostrophe-breaking risk as every other value filter in this repo -- prefer Superblocks
-- bind parameters over raw Mustache substitution.
--
-- DSMB EXCLUSION (base filter, permanent) -- same rule as rolled_out_units_cube.sql: exclude
-- PMCs whose CURRENT live unit total is <=750, by account size only, never by segment label
-- or team ownership. See that file for the full writeup of why.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
rep_units AS (
    SELECT
        s.HUBSPOT_STATIC_TEAM_NAME_DEAL AS team,
        s.HUBSPOT_DEAL_OWNER            AS rep,
        SUM(IFF(s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER,
                s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NOT NULL
      AND s.HUBSPOT_DEAL_OWNER IS NOT NULL
      AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      {{#Segment.value}} AND s.HUBSPOT_COMPANY_SEGMENT = '{{Segment.value}}' {{/Segment.value}}
      {{#Msp.value}}      AND s.PMS = '{{Msp.value}}'                        {{/Msp.value}}
    GROUP BY 1, 2
    HAVING units > 0   -- only reps who actually produced units
),
team_totals AS (
    SELECT team, SUM(units) AS team_units, COUNT(*) AS contributor_count
    FROM rep_units
    GROUP BY 1
)
SELECT
    r.team, r.rep, r.units, t.team_units, t.contributor_count,
    DIV0(r.units, t.team_units) AS rep_share,
    r.rep || ' is driving ' || (t.contributor_count - 1) ||
        IFF(t.contributor_count - 1 = 1, ' other rep''s ', ' other reps'' ') ||
        'worth of ' || r.team || '''s number this month (' ||
        ROUND(DIV0(r.units, t.team_units) * 100, 0) || '% of team total, ' ||
        r.units || ' of ' || t.team_units || ' units)'                        AS callout
FROM rep_units r
JOIN team_totals t ON r.team = t.team
WHERE DIV0(r.units, t.team_units) >= 0.40   -- concentration threshold: tune this
  AND t.team_units >= 20                     -- materiality floor: tune this
  AND t.contributor_count >= 2               -- exclude single-rep pods (trivial 100% share)
ORDER BY rep_share DESC;
