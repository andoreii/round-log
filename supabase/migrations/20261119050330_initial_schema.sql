create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create role round_log_worker nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
grant usage on schema public, private to round_log_worker;
grant usage on schema private to authenticated;

create table public.courses (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  revision integer not null check (revision > 0),
  document jsonb not null check (jsonb_typeof(document) = 'object' and octet_length(document::text) <= 100000),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table public.round_uploads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  round_id uuid not null,
  revision integer not null check (revision > 0),
  payload_version integer not null check (payload_version = 1),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  received_at timestamptz not null default now(),
  unique (user_id, round_id, revision),
  unique (user_id, id)
);

create table private.processing_jobs (
  source_upload_id uuid primary key,
  user_id uuid not null,
  state text not null default 'pending' check (state in ('pending', 'processed', 'invalid')),
  error_code text,
  dispatch_requested_at timestamptz,
  updated_at timestamptz not null default now(),
  foreign key (user_id, source_upload_id) references public.round_uploads(user_id, id) on delete cascade
);
create index processing_jobs_pending_idx on private.processing_jobs (updated_at) where state = 'pending';

create table public.rounds (
  user_id uuid not null,
  id uuid not null,
  source_upload_id uuid not null,
  revision integer not null check (revision > 0),
  transform_version integer not null check (transform_version > 0),
  played_on date not null,
  round_type text not null check (round_type in ('casual', 'competition', 'tournament', 'practice')),
  status text not null check (status in ('completed', 'partial')),
  planned_holes integer not null check (planned_holes in (9, 18)),
  course_id uuid not null,
  course_name text not null,
  course_location text,
  distance_unit text not null check (distance_unit in ('yd', 'm')),
  tee_name text not null,
  weather text,
  notes text,
  created_at timestamptz not null,
  processed_at timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, source_upload_id) references public.round_uploads(user_id, id) on delete cascade,
  unique (user_id, source_upload_id)
);
create index rounds_recent_idx on public.rounds (user_id, played_on desc, created_at desc, id);

create table public.hole_results (
  user_id uuid not null,
  round_id uuid not null,
  number integer not null check (number between 1 and 18),
  par integer not null check (par between 3 and 6),
  stroke_index integer not null check (stroke_index between 1 and 18),
  distance_m numeric not null check (distance_m > 0),
  strokes integer check (strokes > 0),
  putts integer check (putts >= 0),
  penalties integer check (penalties >= 0),
  mode text not null check (mode in ('zen', 'standard', 'detailed')),
  tee_club text,
  tee_x numeric check (tee_x between 0 and 1),
  tee_y numeric check (tee_y between 0 and 1),
  tee_outcome text check (tee_outcome in ('hit','left','right','short','long','short_left','short_right','long_left','long_right')),
  approach_club text,
  approach_x numeric check (approach_x between 0 and 1),
  approach_y numeric check (approach_y between 0 and 1),
  approach_outcome text check (approach_outcome in ('hit','left','right','short','long','short_left','short_right','long_left','long_right')),
  approach_distance_m numeric check (approach_distance_m >= 0),
  primary key (user_id, round_id, number),
  foreign key (user_id, round_id) references public.rounds(user_id, id) on delete cascade,
  check (strokes is not null or (putts is null and penalties is null and tee_club is null and tee_x is null and tee_y is null and tee_outcome is null and approach_club is null and approach_x is null and approach_y is null and approach_outcome is null and approach_distance_m is null)),
  check (strokes is null or coalesce(putts, 0) + coalesce(penalties, 0) <= strokes)
);

create table public.round_preferences (
  user_id uuid not null,
  round_id uuid not null,
  starred boolean not null default false,
  primary key (user_id, round_id),
  foreign key (user_id, round_id) references public.rounds(user_id, id) on delete cascade
);

create table private.pipeline_runs (
  id uuid primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  transform_version integer not null,
  status text not null check (status in ('running', 'succeeded', 'failed')),
  processed_count integer not null default 0 check (processed_count >= 0),
  invalid_count integer not null default 0 check (invalid_count >= 0),
  skipped_count integer not null default 0 check (skipped_count >= 0),
  error_code text
);

alter table public.courses enable row level security;
alter table public.round_uploads enable row level security;
alter table public.rounds enable row level security;
alter table public.hole_results enable row level security;
alter table public.round_preferences enable row level security;
alter table private.processing_jobs enable row level security;
alter table private.pipeline_runs enable row level security;

create policy courses_owner on public.courses to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy uploads_owner_read on public.round_uploads for select to authenticated using ((select auth.uid()) = user_id);
create policy rounds_owner_read on public.rounds for select to authenticated using ((select auth.uid()) = user_id);
create policy holes_owner_read on public.hole_results for select to authenticated using ((select auth.uid()) = user_id);
create policy preferences_owner on public.round_preferences to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy jobs_owner_read on private.processing_jobs for select to authenticated using ((select auth.uid()) = user_id);

create policy worker_uploads_read on public.round_uploads for select to round_log_worker using (true);
create policy worker_rounds on public.rounds to round_log_worker using (true) with check (true);
create policy worker_holes on public.hole_results to round_log_worker using (true) with check (true);
create policy worker_jobs on private.processing_jobs to round_log_worker using (true) with check (true);
create policy worker_runs on private.pipeline_runs to round_log_worker using (true) with check (true);

revoke all on public.courses, public.round_uploads, public.rounds, public.hole_results, public.round_preferences from public, anon, authenticated;
revoke all on private.processing_jobs, private.pipeline_runs from public, anon, authenticated;
grant select, insert, update, delete on public.courses, public.round_preferences to authenticated;
grant select on public.round_uploads, public.rounds, public.hole_results to authenticated;
grant select (source_upload_id, user_id, state, error_code, updated_at) on private.processing_jobs to authenticated;
grant select on public.round_uploads to round_log_worker;
grant select, insert, update on public.rounds to round_log_worker;
grant select, insert, delete on public.hole_results to round_log_worker;
grant select, update on private.processing_jobs to round_log_worker;
grant select, insert, update on private.pipeline_runs to round_log_worker;

-- Clients cannot write raw uploads or jobs directly; the private entry point checks ownership.
create function private.ingest_round(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  target_id uuid;
  target_revision integer;
  upload public.round_uploads;
  job private.processing_jobs;
  is_duplicate boolean := false;
  should_dispatch boolean;
begin
  if owner_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if jsonb_typeof(payload) is distinct from 'object' or octet_length(payload::text) > 65536
     or payload->'schema_version' is distinct from '1'::jsonb
     or jsonb_typeof(payload->'round_id') is distinct from 'string'
     or jsonb_typeof(payload->'revision') is distinct from 'number'
     or not (payload->>'revision' ~ '^[1-9][0-9]{0,8}$') then
    raise exception using errcode = '22023', message = 'invalid_envelope';
  end if;
  begin
    target_id := (payload->>'round_id')::uuid;
    target_revision := (payload->>'revision')::integer;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'invalid_envelope';
  end;
  insert into public.round_uploads (user_id, round_id, revision, payload_version, payload)
  values (owner_id, target_id, target_revision, 1, payload)
  on conflict (user_id, round_id, revision) do nothing returning * into upload;
  if upload.id is null then
    is_duplicate := true;
    select * into strict upload from public.round_uploads
    where user_id = owner_id and round_id = target_id and revision = target_revision;
    if upload.payload <> payload then
      raise exception using errcode = '22023', message = 'revision_conflict';
    end if;
  else
    insert into private.processing_jobs (source_upload_id, user_id) values (upload.id, owner_id);
  end if;
  select * into strict job from private.processing_jobs where source_upload_id = upload.id for update;
  should_dispatch := job.state = 'pending' and
    (job.dispatch_requested_at is null or job.dispatch_requested_at <= now() - interval '60 seconds');
  if should_dispatch then
    update private.processing_jobs set dispatch_requested_at = now() where source_upload_id = upload.id;
  end if;
  return jsonb_build_object('upload_id', upload.id, 'round_id', target_id, 'revision', target_revision,
    'state', job.state, 'duplicate', is_duplicate, 'dispatch_needed', should_dispatch);
end;
$$;
revoke all on function private.ingest_round(jsonb) from public, anon;
grant execute on function private.ingest_round(jsonb) to authenticated;

create function public.submit_round(payload jsonb) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.ingest_round(payload);
$$;
revoke all on function public.submit_round(jsonb) from public, anon;
grant execute on function public.submit_round(jsonb) to authenticated;

create view public.latest_round_status with (security_invoker = true) as
select distinct on (u.user_id, u.round_id)
  u.user_id, u.round_id, u.id as upload_id, u.revision, u.received_at,
  j.state, j.error_code, j.updated_at
from public.round_uploads u join private.processing_jobs j
  on j.source_upload_id = u.id and j.user_id = u.user_id
order by u.user_id, u.round_id, u.revision desc;

create view public.latest_twenty_rounds with (security_invoker = true) as
select r.* from (
  select rounds.*, row_number() over (partition by user_id order by played_on desc, created_at desc, id) as recency
  from public.rounds
 ) r join public.latest_round_status latest
  on latest.user_id = r.user_id and latest.round_id = r.id
  and latest.revision = r.revision and latest.state = 'processed'
where recency <= 20;

create view public.round_summaries with (security_invoker = true) as
select r.user_id, r.id as round_id, r.revision, r.played_on, r.planned_holes, r.status,
  count(h.strokes) as holes_played,
  sum(h.strokes) as total_strokes,
  sum(h.strokes - h.par) as score_to_par,
  sum(h.putts) as recorded_putts,
  count(h.putts) as putting_sample,
  count(*) filter (where h.putts >= 3) as three_putt_holes,
  avg(h.putts) as putts_per_recorded_hole,
  sum(h.penalties) as recorded_penalties,
  count(h.penalties) as penalty_sample,
  count(*) filter (where h.penalties > 0) as penalized_holes,
  count(*) filter (where h.par > 3 and h.tee_outcome is not null) as fairway_sample,
  count(*) filter (where h.par > 3 and h.tee_outcome = 'hit') as fairways_hit,
  count(*) filter (where h.approach_outcome is not null) as approach_sample,
  count(*) filter (where h.approach_outcome = 'hit') as approaches_hit
from public.rounds r join public.hole_results h on h.user_id = r.user_id and h.round_id = r.id
join public.latest_round_status latest on latest.user_id = r.user_id and latest.round_id = r.id
  and latest.revision = r.revision and latest.state = 'processed'
where h.strokes is not null
group by r.user_id, r.id;

create view public.latest_twenty_metrics with (security_invoker = true) as
select s.user_id, s.planned_holes, s.status,
  count(*) as round_sample, sum(s.holes_played) as holes_played,
  avg(s.total_strokes) as average_strokes, avg(s.score_to_par) as average_score_to_par,
  sum(s.recorded_putts)::numeric / nullif(sum(s.putting_sample), 0) as putts_per_recorded_hole,
  sum(s.putting_sample) as putting_sample,
  sum(s.three_putt_holes)::numeric / nullif(sum(s.putting_sample), 0) as three_putt_rate,
  sum(s.fairways_hit)::numeric / nullif(sum(s.fairway_sample), 0) as fairway_hit_rate,
  sum(s.fairway_sample) as fairway_sample,
  sum(s.approaches_hit)::numeric / nullif(sum(s.approach_sample), 0) as approach_hit_rate,
  sum(s.approach_sample) as approach_sample,
  sum(s.recorded_penalties) as recorded_penalties, sum(s.penalty_sample) as penalty_sample,
  sum(s.penalized_holes)::numeric / nullif(sum(s.penalty_sample), 0) as penalty_hole_rate,
  sum(s.recorded_penalties)::numeric / nullif(sum(s.penalty_sample), 0) as penalties_per_recorded_hole
from public.round_summaries s join public.latest_twenty_rounds r on r.user_id = s.user_id and r.id = s.round_id
group by s.user_id, s.planned_holes, s.status;

create view public.latest_twenty_shots with (security_invoker = true) as
select h.* from public.hole_results h join public.latest_twenty_rounds r
  on r.user_id = h.user_id and r.id = h.round_id
where h.strokes is not null;

revoke all on public.latest_round_status, public.latest_twenty_rounds, public.round_summaries,
  public.latest_twenty_metrics, public.latest_twenty_shots from public, anon;
grant select on public.latest_round_status, public.latest_twenty_rounds, public.round_summaries,
  public.latest_twenty_metrics, public.latest_twenty_shots to authenticated;
