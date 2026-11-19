begin;

do $$
declare
  owner_id uuid := gen_random_uuid();
  other_id uuid := gen_random_uuid();
  target_round_id uuid := gen_random_uuid();
  document jsonb;
  first_result jsonb;
  retry_result jsonb;
  target_upload uuid;
  changed jsonb;
  metric record;
begin
  insert into auth.users (id) values (owner_id), (other_id);
  select jsonb_build_object(
    'schema_version', 1, 'round_id', target_round_id, 'revision', 1,
    'played_on', '2026-11-01', 'created_at', '2026-11-01T01:00:00Z',
    'round_type', 'practice', 'status', 'completed', 'planned_holes', 9,
    'course', jsonb_build_object('id', gen_random_uuid(), 'name', 'Sample Links', 'location', 'Test course', 'distance_unit', 'yd'),
    'tee', jsonb_build_object('name', 'White'),
    'holes', jsonb_agg(jsonb_build_object('number', n, 'par', 4, 'stroke_index', n, 'distance', 400,
      'strokes', 5, 'putts', null, 'penalties', null, 'mode', 'zen', 'tee_shot', null, 'approach_shot', null))
  ) into document from generate_series(1, 9) n;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  first_result := public.submit_round(document);
  retry_result := public.submit_round(document);
  target_upload := (first_result->>'upload_id')::uuid;
  assert first_result->>'state' = 'pending';
  assert first_result->'dispatch_needed' = 'true'::jsonb;
  assert retry_result->>'upload_id' = first_result->>'upload_id';
  assert retry_result->'duplicate' = 'true'::jsonb;
  assert retry_result->'dispatch_needed' = 'false'::jsonb;

  begin
    perform public.submit_round(jsonb_set(document, '{notes}', '"changed"'));
    raise exception 'conflicting_revision_accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    update public.round_uploads set payload = payload where id = target_upload;
    raise exception 'raw_update_accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    update private.processing_jobs set state = 'processed' where source_upload_id = target_upload;
    raise exception 'client_job_update_accepted';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', other_id::text, true);
  assert (select count(*) from public.round_uploads) = 0;
  assert (select count(*) from public.latest_round_status) = 0;
  begin
    execute 'set local role anon';
    perform count(*) from public.rounds;
    raise exception 'anonymous_read_accepted';
  exception when insufficient_privilege then null;
  end;

  execute 'set local role round_log_worker';
  assert (select not rolbypassrls from pg_roles where rolname = 'round_log_worker');
  insert into public.rounds (user_id, id, source_upload_id, revision, transform_version, played_on, round_type,
    status, planned_holes, course_id, course_name, course_location, distance_unit, tee_name, created_at)
  values (owner_id, target_round_id, target_upload, 1, 1, '2026-11-01', 'practice', 'completed', 9,
    (document->'course'->>'id')::uuid, 'Sample Links', 'Test course', 'yd', 'White', '2026-11-01T01:00:00Z');
  insert into public.hole_results (user_id, round_id, number, par, stroke_index, distance_m, strokes, mode)
  select owner_id, target_round_id, n, 4, n, 365.7600, 5, 'zen' from generate_series(1, 9) n;
  update private.processing_jobs set state = 'processed' where source_upload_id = target_upload;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  select * into strict metric from public.latest_twenty_metrics;
  assert metric.round_sample = 1 and metric.holes_played = 9;
  assert metric.average_strokes = 45 and metric.average_score_to_par = 9;
  assert metric.putting_sample = 0 and metric.putts_per_recorded_hole is null;
  assert metric.fairway_sample = 0 and metric.fairway_hit_rate is null;
  assert metric.penalty_sample = 0 and metric.penalty_hole_rate is null;
  begin
    update public.rounds set notes = 'blocked' where id = target_round_id;
    raise exception 'client_clean_update_accepted';
  exception when insufficient_privilege then null;
  end;

  changed := jsonb_set(document, '{revision}', '2');
  perform public.submit_round(changed);
  assert (select count(*) from public.latest_twenty_metrics) = 0;
  execute 'set local role round_log_worker';
  update private.processing_jobs set state = 'invalid', error_code = 'inconsistent_strokes'
  where source_upload_id = (select id from public.round_uploads u where u.user_id = owner_id and u.round_id = target_round_id and revision = 2);
  execute 'set local role authenticated';
  assert (select count(*) from public.latest_twenty_metrics) = 0;
  assert (select state from public.latest_round_status) = 'invalid';
  assert (select revision from public.rounds) = 1;
end;
$$;

rollback;
