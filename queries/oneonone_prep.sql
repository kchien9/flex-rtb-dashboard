-- 1:1 Prep -- structures Sham's 1:1s with his 5 direct reports (Brandon, Dana, Rory,
-- Sebastian, Hans): high-level slice of their team, plus highlights/flags/trends so there's
-- always something concrete to talk about, not just "how's it going."
--
-- MANAGER ROSTER -- there is no clean manager-hierarchy field on the CRM side for this.
-- HUBSPOT_STATIC_TEAM_NAME_DEAL only has personalized team names for some managers
-- (Brandon's Team, Cory's Team, Heidi's Team) -- Rory, Sebastian, Dana, Hans's reports sit
-- under generic pod names (SMB Manager, Enterprise AE Manager, SDR Leadership) that don't
-- say which specific reps are theirs. The real source is Rippling (HR data), already used
-- by flex-comp-engine via comp_config_v4.xlsx's Rippling_Raw tab (reporting_to column) --
-- confirmed real rosters for 3 of 5 managers as of 2026-07-27:
--   Brandon Nicastro (6): Jenny Harrington, Umar Khan, Sunny Harden, Ally Yates,
--     Katie Brenes, Casey Grieshop
--   Rory Averett (8): Max Freund, Eli Greenberg, Ethan Sherman, Alyssa Freeman,
--     Jacob Fidler, Redding Tews, Caleb Benson, Tracy Do
--   Sebastian Bohlmann (9): Michael Brizuela, Veronica Breeden, Pedro Arias,
--     Luke McCarthy, Dani Bamber, Ruby Baer, Aaryn Chandler, Fiona Landers, Spencer Kendall
--   Hans Bredahl (13 reports) -- SDRs, not AEs, needs the activity-side tables
--     (FCT_CRM_TASK/FCT_CRM_MEETING), not this units-side query. Not yet built.
--   Dana Finch -- DOES NOT APPEAR in Rippling_Raw as a manager or a report. Real gap, not
--     guessed at -- either a name-spelling mismatch or her team isn't in this roster file.
--     Needs Kevin to confirm before her 1:1 card can be built for real.
--
-- No CREATE TABLE access on this Snowflake role, so the roster is embedded as a VALUES CTE --
-- same pattern already used for ALN data in flex-voyager (see that repo's
-- scripts/inject_aln_ctes.py). This roster WILL drift as reps join/leave/get reassigned --
-- needs a refresh process, not a one-time hardcode. Superblocks alternative: a small seed
-- table/reference sheet Kevin maintains directly, same idea, less brittle than editing SQL.
--
-- Validated against live Snowflake 2026-07-27 -- real team-level numbers, current vs. prior
-- BP month, Integrated Total units:
--   Brandon Nicastro: 1,772,387 (was 1,760,447)
--   Sebastian Bohlmann: 997,693 (was 968,628)
--   Rory Averett: 724,281 (was 713,225)

WITH manager_roster AS (
    SELECT * FROM VALUES
        ('Jenny Harrington','Brandon Nicastro'), ('Umar Khan','Brandon Nicastro'), ('Sunny Harden','Brandon Nicastro'),
        ('Ally Yates','Brandon Nicastro'), ('Katie Brenes','Brandon Nicastro'), ('Casey Grieshop','Brandon Nicastro'),
        ('Max Freund','Rory Averett'), ('Eli Greenberg','Rory Averett'), ('Ethan Sherman','Rory Averett'),
        ('Alyssa Freeman','Rory Averett'), ('Jacob Fidler','Rory Averett'), ('Redding Tews','Rory Averett'),
        ('Caleb Benson','Rory Averett'), ('Tracy Do','Rory Averett'),
        ('Michael Brizuela','Sebastian Bohlmann'), ('Veronica Breeden','Sebastian Bohlmann'), ('Pedro Arias','Sebastian Bohlmann'),
        ('Luke McCarthy','Sebastian Bohlmann'), ('Dani Bamber','Sebastian Bohlmann'), ('Ruby Baer','Sebastian Bohlmann'),
        ('Aaryn Chandler','Sebastian Bohlmann'), ('Fiona Landers','Sebastian Bohlmann'), ('Spencer Kendall','Sebastian Bohlmann')
    AS t(rep, manager)
)
-- Part A: team-level high-level slice, per manager
SELECT
    r.manager,
    SUM(IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
            AND s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0))                              AS units_this,
    SUM(IFF(s.BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
            AND s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0))                              AS units_last
FROM manager_roster r
LEFT JOIN PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s ON s.HUBSPOT_DEAL_OWNER = r.rep
{{#Manager.value}} WHERE r.manager = '{{Manager.value}}' {{/Manager.value}}
GROUP BY 1;

-- Part B: "something to talk about" -- reuse insights_driver_concentration.sql's pattern,
-- scoped to one manager's roster, to surface which of their reps is up/down this month.
-- WITH manager_roster AS ( ...same as above... )
-- SELECT r.rep,
--     SUM(IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
--             AND s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS units_this,
--     SUM(IFF(s.BP_MONTH = DATEADD(month,-1,(SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
--             AND s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS units_last
-- FROM manager_roster r
-- LEFT JOIN PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s ON s.HUBSPOT_DEAL_OWNER = r.rep
-- WHERE r.manager = '{{ Manager.value }}'
-- GROUP BY 1
-- ORDER BY (units_this - units_last) DESC;  -- biggest mover, up or down, per rep
