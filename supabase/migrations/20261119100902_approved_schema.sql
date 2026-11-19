alter table public.round_uploads
  add column played_on date,
  add column created_at timestamptz;

do $$
begin
  if exists (select 1 from public.round_uploads
    where jsonb_typeof(payload->'played_on') is distinct from 'string'
      or payload->>'played_on' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or jsonb_typeof(payload->'created_at') is distinct from 'string'
      or payload->>'created_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.][0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$') then
    raise exception 'existing_uploads_require_review';
  end if;
end;
$$;

update public.round_uploads
set played_on = (payload->>'played_on')::date,
    created_at = (payload->>'created_at')::timestamptz;

do $$
begin
  if exists (select 1 from public.round_uploads group by user_id, round_id
    having min(created_at) <> max(created_at)) then
    raise exception 'existing_upload_creation_times_conflict';
  end if;
end;
$$;

alter table public.round_uploads
  alter column played_on set not null,
  alter column created_at set not null,
  add constraint round_uploads_payload_size check (octet_length(payload::text) <= 65536);

create index round_uploads_recent_idx
  on public.round_uploads (user_id, played_on desc, created_at desc, round_id);

alter table public.rounds
  add column tee_id uuid,
  add column course_rating numeric,
  add column slope_rating integer,
  add constraint rounds_course_rating check (
    course_rating > 0 and course_rating < 'Infinity'::numeric and course_rating = round(course_rating, 1)),
  add constraint rounds_slope_rating check (slope_rating between 55 and 155);

update public.rounds r set tee_id = (u.payload#>>'{tee,id}')::uuid
from public.round_uploads u where u.user_id = r.user_id and u.id = r.source_upload_id;

alter table public.rounds alter column tee_id set not null;
alter table public.hole_results
  add constraint hole_tee_coordinate_pair check ((tee_x is null) = (tee_y is null)),
  add constraint hole_approach_coordinate_pair check ((approach_x is null) = (approach_y is null));

revoke insert, update, delete on public.courses from authenticated;
drop policy courses_owner on public.courses;
create policy courses_owner_read on public.courses for select to authenticated
  using ((select auth.uid()) = user_id);

create function private.save_course(course_id uuid, revision integer, document jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  target_id uuid := course_id;
  target_revision integer := revision;
  course_document jsonb := document;
  stored public.courses;
  hole jsonb;
  tee jsonb;
  distance jsonb;
  rating jsonb;
  rating_scope text;
  hole_count integer;
  hole_number integer;
  stroke_index integer;
  tee_id uuid;
  hole_numbers integer[] := '{}';
  stroke_indexes integer[] := '{}';
  distance_numbers integer[];
  tee_ids uuid[] := '{}';
begin
  if owner_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if target_id is null or target_revision is null or target_revision <= 0
     or jsonb_typeof(course_document) is distinct from 'object'
     or octet_length(course_document::text) > 100000
     or jsonb_typeof(course_document->'schema_version') is distinct from 'number'
     or course_document->>'schema_version' is distinct from '1'
     or jsonb_typeof(course_document->'name') is distinct from 'string'
     or course_document->>'name' !~ '[^[:space:]]' or length(course_document->>'name') > 200
     or (course_document->'location' is not null and course_document->'location' <> 'null'::jsonb
         and (jsonb_typeof(course_document->'location') <> 'string' or length(course_document->>'location') > 300))
     or jsonb_typeof(course_document->'archived') is distinct from 'boolean'
     or course_document->>'distance_unit' is null or course_document->>'distance_unit' not in ('yd', 'm')
     or jsonb_typeof(course_document->'holes') is distinct from 'array'
     or jsonb_typeof(course_document->'tees') is distinct from 'array' then
    raise exception using errcode = '22023', message = 'invalid_course';
  end if;
  hole_count := jsonb_array_length(course_document->'holes');
  if hole_count not in (9, 18) or jsonb_array_length(course_document->'tees') = 0 then
    raise exception using errcode = '22023', message = 'invalid_course';
  end if;
  for hole in select value from jsonb_array_elements(course_document->'holes') loop
    if jsonb_typeof(hole) is distinct from 'object'
       or jsonb_typeof(hole->'number') is distinct from 'number' or hole->>'number' !~ '^([1-9]|1[0-8])$'
       or jsonb_typeof(hole->'par') is distinct from 'number' or hole->>'par' !~ '^[3-6]$'
       or jsonb_typeof(hole->'stroke_index') is distinct from 'number' or hole->>'stroke_index' !~ '^([1-9]|1[0-8])$' then
      raise exception using errcode = '22023', message = 'invalid_course';
    end if;
    hole_number := (hole->>'number')::integer;
    stroke_index := (hole->>'stroke_index')::integer;
    if hole_number > hole_count or hole_number = any(hole_numbers) or stroke_index = any(stroke_indexes) then
      raise exception using errcode = '22023', message = 'invalid_course';
    end if;
    hole_numbers := array_append(hole_numbers, hole_number);
    stroke_indexes := array_append(stroke_indexes, stroke_index);
  end loop;
  for tee in select value from jsonb_array_elements(course_document->'tees') loop
    if jsonb_typeof(tee) is distinct from 'object'
       or jsonb_typeof(tee->'id') is distinct from 'string'
       or jsonb_typeof(tee->'name') is distinct from 'string'
       or tee->>'name' !~ '[^[:space:]]' or length(tee->>'name') > 100
       or jsonb_typeof(tee->'distances') is distinct from 'array' then
      raise exception using errcode = '22023', message = 'invalid_course';
    end if;
    begin
      tee_id := (tee->>'id')::uuid;
    exception when invalid_text_representation then
      raise exception using errcode = '22023', message = 'invalid_course';
    end;
    if tee_id = any(tee_ids) or jsonb_array_length(tee->'distances') <> hole_count then
      raise exception using errcode = '22023', message = 'invalid_course';
    end if;
    tee_ids := array_append(tee_ids, tee_id);
    distance_numbers := '{}';
    for distance in select value from jsonb_array_elements(tee->'distances') loop
      if jsonb_typeof(distance) is distinct from 'object'
         or jsonb_typeof(distance->'number') is distinct from 'number' or distance->>'number' !~ '^([1-9]|1[0-8])$'
         or jsonb_typeof(distance->'distance') is distinct from 'number' then
        raise exception using errcode = '22023', message = 'invalid_course';
      end if;
      hole_number := (distance->>'number')::integer;
      if hole_number > hole_count or hole_number = any(distance_numbers) or (distance->>'distance')::numeric <= 0 then
        raise exception using errcode = '22023', message = 'invalid_course';
      end if;
      distance_numbers := array_append(distance_numbers, hole_number);
    end loop;
    if tee->'ratings' is not null and tee->'ratings' <> 'null'::jsonb then
      if jsonb_typeof(tee->'ratings') <> 'object' then
        raise exception using errcode = '22023', message = 'invalid_course';
      end if;
      for rating_scope, rating in select key, value from jsonb_each(tee->'ratings') loop
        if rating_scope not in ('full', 'front_nine', 'back_nine')
           or (hole_count = 9 and rating_scope <> 'full') then
          raise exception using errcode = '22023', message = 'invalid_course';
        end if;
        if rating = 'null'::jsonb then
          continue;
        end if;
        if jsonb_typeof(rating) <> 'object' then
          raise exception using errcode = '22023', message = 'invalid_course';
        end if;
        if exists (select 1 from jsonb_object_keys(rating) k where k not in ('course_rating', 'slope_rating')) then
          raise exception using errcode = '22023', message = 'invalid_course';
        end if;
        if rating->'course_rating' is not null and rating->'course_rating' <> 'null'::jsonb then
          if jsonb_typeof(rating->'course_rating') <> 'number' then
            raise exception using errcode = '22023', message = 'invalid_course';
          end if;
          if (rating->>'course_rating')::numeric <= 0 or (rating->>'course_rating')::numeric >= 'Infinity'::numeric
             or (rating->>'course_rating')::numeric <> round((rating->>'course_rating')::numeric, 1) then
            raise exception using errcode = '22023', message = 'invalid_course';
          end if;
        end if;
        if rating->'slope_rating' is not null and rating->'slope_rating' <> 'null'::jsonb then
          if jsonb_typeof(rating->'slope_rating') <> 'number'
             or rating->>'slope_rating' !~ '^(5[5-9]|[6-9][0-9]|1[0-4][0-9]|15[0-5])$' then
            raise exception using errcode = '22023', message = 'invalid_course';
          end if;
        end if;
      end loop;
    end if;
  end loop;
  perform pg_advisory_xact_lock(1, hashtext(owner_id::text || target_id::text));
  select * into stored from public.courses where user_id = owner_id and id = target_id;
  if stored.id is not null then
    if target_revision < stored.revision then
      raise exception using errcode = '22023', message = 'stale_revision';
    elsif target_revision = stored.revision then
      if stored.document <> course_document then
        raise exception using errcode = '22023', message = 'revision_conflict';
      end if;
      return jsonb_build_object('course_id', target_id, 'revision', target_revision, 'duplicate', true);
    end if;
  end if;
  insert into public.courses (user_id, id, revision, document)
  values (owner_id, target_id, target_revision, course_document)
  on conflict (user_id, id) do update
    set revision = excluded.revision, document = excluded.document, updated_at = now();
  return jsonb_build_object('course_id', target_id, 'revision', target_revision, 'duplicate', false);
end;
$$;
revoke all on function private.save_course(uuid, integer, jsonb) from public, anon;
grant execute on function private.save_course(uuid, integer, jsonb) to authenticated;

create function public.save_course(course_id uuid, revision integer, document jsonb) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.save_course(course_id, revision, document);
$$;
revoke all on function public.save_course(uuid, integer, jsonb) from public, anon;
grant execute on function public.save_course(uuid, integer, jsonb) to authenticated;

create or replace function private.ingest_round(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  target_id uuid;
  target_revision integer;
  target_played_on date;
  target_created_at timestamptz;
  original_created_at timestamptz;
  upload public.round_uploads;
  job private.processing_jobs;
  is_duplicate boolean := false;
  should_dispatch boolean;
begin
  if owner_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if jsonb_typeof(payload) is distinct from 'object' or octet_length(payload::text) > 65536
     or jsonb_typeof(payload->'schema_version') is distinct from 'number'
     or payload->>'schema_version' is distinct from '1'
     or jsonb_typeof(payload->'round_id') is distinct from 'string'
     or jsonb_typeof(payload->'revision') is distinct from 'number'
     or not (payload->>'revision' ~ '^[1-9][0-9]{0,8}$')
     or jsonb_typeof(payload->'played_on') is distinct from 'string'
     or payload->>'played_on' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     or jsonb_typeof(payload->'created_at') is distinct from 'string'
     or payload->>'created_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.][0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$' then
    raise exception using errcode = '22023', message = 'invalid_envelope';
  end if;
  begin
    target_id := (payload->>'round_id')::uuid;
    target_revision := (payload->>'revision')::integer;
    target_played_on := (payload->>'played_on')::date;
    target_created_at := (payload->>'created_at')::timestamptz;
  exception when invalid_text_representation or numeric_value_out_of_range or datetime_field_overflow or invalid_datetime_format then
    raise exception using errcode = '22023', message = 'invalid_envelope';
  end;
  -- This two-key lock is separate from the worker's bigint lock, which follows a job-row lock.
  perform pg_advisory_xact_lock(2, hashtext(owner_id::text || target_id::text));
  select created_at into original_created_at from public.round_uploads
    where user_id = owner_id and round_id = target_id order by revision desc limit 1;
  if original_created_at is not null and original_created_at <> target_created_at then
    raise exception using errcode = '22023', message = 'created_at_conflict';
  end if;
  insert into public.round_uploads (user_id, round_id, revision, payload_version, played_on, created_at, payload)
  values (owner_id, target_id, target_revision, 1, target_played_on, target_created_at, payload)
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

create or replace view public.latest_twenty_rounds with (security_invoker = true) as
with latest_uploads as (
  select distinct on (user_id, round_id) user_id, round_id, id, revision, played_on, created_at
  from public.round_uploads order by user_id, round_id, revision desc
), recent as (
  select latest_uploads.*,
    row_number() over (partition by user_id order by played_on desc, created_at desc, round_id) as recency
  from latest_uploads
)
select r.user_id, r.id, r.source_upload_id, r.revision, r.transform_version, r.played_on,
  r.round_type, r.status, r.planned_holes, r.course_id, r.course_name, r.course_location,
  r.distance_unit, r.tee_name, r.weather, r.notes, r.created_at, r.processed_at, recent.recency,
  r.tee_id, r.course_rating, r.slope_rating
from recent join public.rounds r on r.user_id = recent.user_id and r.id = recent.round_id
  and r.source_upload_id = recent.id and r.revision = recent.revision
join private.processing_jobs j on j.source_upload_id = recent.id and j.user_id = recent.user_id
  and j.state = 'processed'
where recent.recency <= 20;
