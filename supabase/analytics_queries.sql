-- Restaurant Journal — analytics queries
-- Paste any of these into Supabase → SQL Editor:
--   https://supabase.com/dashboard/project/djjrmnpqyywploerecpr/sql/new
--
-- Events that fire in the App Store (Release) build:
--   app_open, onboarding_completed, scan_completed, visit_created, visit_viewed,
--   rating_set, map_opened, loyalty_join_tapped
-- (signed_in/out, card_connected, ask_used are dev-only — accounts/cards/Ask are gated out.)
-- Every event also carries: install_id, session (props->>'session'), authenticated, app_version.
-- visit_created also carries: is_repeat (bool), visit_number (int).


-- === HEADLINE TOTALS ===
-- Total photos scanned ("Rescan all" re-scans everything, so this is scanning activity).
select coalesce(sum((props->>'photos_scanned')::int), 0) as total_photos_scanned
from events where name = 'scan_completed';

-- Total visits created.
select count(*) as total_visits_created
from events where name = 'visit_created';


-- === REPEAT DINING VISITS (north-star: habitual, not one-and-done) ===
select
  count(*) filter (where (props->>'is_repeat')::boolean)                as repeat_visits,
  count(*)                                                              as total_visits,
  round(100.0 * count(*) filter (where (props->>'is_repeat')::boolean)
        / nullif(count(*), 0), 1)                                       as repeat_pct
from events where name = 'visit_created';

-- Loyalty depth: how many 2nd, 3rd, 5th… visits to the same place.
select (props->>'visit_number')::int as visit_number, count(*) as visits
from events where name = 'visit_created'
group by 1 order by 1;

-- Most habitual installs (repeat visits each).
select install_id,
       count(*)                                               as visits,
       count(*) filter (where (props->>'is_repeat')::boolean) as repeat_visits
from events where name = 'visit_created'
group by 1 order by repeat_visits desc limit 25;


-- === SCAN SUCCESS: photos scanned → visits added ===
select
  count(*)                                              as scans,
  sum((props->>'photos_scanned')::int)                 as photos_scanned,
  sum((props->>'visits_added')::int)                   as visits_added,
  round(100.0 * sum((props->>'visits_added')::int)
        / nullif(sum((props->>'photos_scanned')::int), 0), 2) as visits_per_100_photos
from events
where name = 'scan_completed';


-- === TIME SERIES (for graphing: scans / visits / repeat visits over time) ===
-- SQL Editor shows a table; to draw a line, paste into Sheets, or build a chart in
-- Dashboard → Reports (New chart → SQL) which renders these as line graphs directly.
-- Swap 'day' for 'week' or 'month' in any date_trunc to change the bucket.

-- Scans over time (photos scanned + visits added per day).
select
  date_trunc('day', created_at)::date  as day,
  count(*)                             as scans,
  sum((props->>'photos_scanned')::int) as photos_scanned,
  sum((props->>'visits_added')::int)   as visits_added
from events
where name = 'scan_completed'
group by 1
order by 1;

-- Visits added over time (one row per created visit — cleaner than scan-reported counts).
select
  date_trunc('day', created_at)::date as day,
  count(*)                            as visits_added
from events
where name = 'visit_created'
group by 1
order by 1;

-- Repeat dining visits over time (habit forming — the north-star curve).
select
  date_trunc('day', created_at)::date                                as day,
  count(*) filter (where (props->>'is_repeat')::boolean)             as repeat_visits,
  count(*)                                                           as all_visits
from events
where name = 'visit_created'
group by 1
order by 1;

-- Cumulative (running totals) — the "up and to the right" version of the three above.
select
  day,
  sum(visits_added)  over (order by day) as cumulative_visits,
  sum(repeat_visits) over (order by day) as cumulative_repeat_visits
from (
  select
    date_trunc('day', created_at)::date                     as day,
    count(*)                                                as visits_added,
    count(*) filter (where (props->>'is_repeat')::boolean)  as repeat_visits
  from events
  where name = 'visit_created'
  group by 1
) d
order by day;


-- === VISITS PER BRAND (chains vs "Independent") ===
select props->>'brand' as brand, count(*) as visits
from events
where name = 'visit_created'
group by 1
order by visits desc;


-- === SESSIONS PER DAY (opens + unique installs) ===
select
  date_trunc('day', created_at)::date as day,
  count(*)                            as opens,
  count(distinct install_id)          as unique_installs,
  count(distinct props->>'session')   as sessions
from events
where name = 'app_open'
group by 1
order by 1 desc;


-- === LOCATIONS VIEWED PER SESSION ===
select round(avg(views), 2) as avg_visits_viewed_per_session
from (
  select props->>'session' as session, count(*) as views
  from events
  where name = 'visit_viewed'
  group by 1
) t;


-- === ONBOARDING / ACTIVATION FUNNEL ===
select
  count(distinct install_id) filter (where name = 'app_open')             as installs,
  count(distinct install_id) filter (where name = 'onboarding_completed') as onboarded,
  count(distinct install_id) filter (where name = 'scan_completed')       as scanned,
  count(distinct install_id) filter (where name = 'visit_created')        as got_a_visit;


-- === RATINGS BREAKDOWN ===
select props->>'rating' as rating, count(*) from events
where name = 'rating_set' group by 1 order by 2 desc;


-- === LOYALTY "JOIN" TAPS BY BRAND ===
select props->>'brand' as brand, count(*) from events
where name = 'loyalty_join_tapped' group by 1 order by 2 desc;
