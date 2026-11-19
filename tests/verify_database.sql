begin;

do $$
declare
  owner_id uuid := gen_random_uuid();
  other_id uuid := gen_random_uuid();
  window_owner_id uuid := gen_random_uuid();
  target_round_id uuid := gen_random_uuid();
  course_id uuid := gen_random_uuid();
  tee_id uuid := gen_random_uuid();
  course_document jsonb;
  bad_document jsonb;
  document jsonb;
  first_result jsonb;
  retry_result jsonb;
  target_upload uuid;
  changed jsonb;
  window_document jsonb;
  window_round_id uuid;
  oldest_round_id uuid;
  pending_round_id uuid;
  window_upload uuid;
  window_index integer;
  metric record;
begin
  insert into auth.users (id) values (owner_id), (other_id), (window_owner_id);
  select jsonb_build_object(
    'schema_version', 1, 'name', 'Sample Links', 'location', 'Test course',
    'archived', false, 'distance_unit', 'yd',
    'holes', jsonb_agg(jsonb_build_object('number', h, 'par', 4, 'stroke_index', h)),
    'tees', jsonb_build_array(jsonb_build_object('id', tee_id, 'name', 'White',
      'distances', jsonb_agg(jsonb_build_object('number', h, 'distance', 400)),
      'ratings', jsonb_build_object('full', jsonb_build_object('course_rating', 35.4, 'slope_rating', 120))))
  ) into course_document from generate_series(1, 9) h;
  select jsonb_build_object(
    'schema_version', 1, 'round_id', target_round_id, 'revision', 1,
    'played_on', '2026-11-01', 'created_at', '2026-11-01T01:00:00Z',
    'round_type', 'practice', 'status', 'completed', 'planned_holes', 9,
    'course', jsonb_build_object('id', course_id, 'name', 'Sample Links', 'location', 'Test course', 'distance_unit', 'yd', 'hole_count', 9),
    'tee', jsonb_build_object('id', tee_id, 'name', 'White', 'ratings', course_document#>'{tees,0,ratings}'),
    'holes', jsonb_agg(jsonb_build_object('number', h, 'par', 4, 'stroke_index', h, 'distance', 400,
      'strokes', 5, 'putts', null, 'penalties', null, 'mode', 'zen', 'tee_shot', null, 'approach_shot', null))
  ) into document from generate_series(1, 9) h;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  first_result := public.save_course(course_id, 1, course_document);
  retry_result := public.save_course(course_id, 1, course_document);
  assert (first_result->>'course_id')::uuid = course_id and (first_result->>'revision')::integer = 1;
  assert first_result->'duplicate' = 'false'::jsonb and retry_result->'duplicate' = 'true'::jsonb;
  changed := jsonb_set(course_document, '{name}', '"Updated Links"');
  perform public.save_course(course_id, 2, changed);
  begin
    perform public.save_course(course_id, 2, course_document);
    raise exception 'course_conflicting_revision_accepted';
  exception when invalid_parameter_value then assert sqlerrm = 'revision_conflict';
  end;
  begin
    perform public.save_course(course_id, 1, course_document);
    raise exception 'course_stale_revision_accepted';
  exception when invalid_parameter_value then assert sqlerrm = 'stale_revision';
  end;
  foreach bad_document in array array[
    course_document - 'name',
    course_document #- '{holes,8}',
    jsonb_set(course_document, '{holes,1,stroke_index}', '1'),
    jsonb_set(course_document, '{tees,0,distances,0,distance}', '0'),
    jsonb_set(course_document, '{tees,0,ratings,full,slope_rating}', '54'),
    jsonb_set(course_document, '{tees,0,ratings,full,course_rating}', '35.45'),
    jsonb_set(course_document, '{tees,0,ratings}', '{"front_nine":{"course_rating":35.4}}')
  ] loop
    begin
      perform public.save_course(gen_random_uuid(), 1, bad_document);
      raise exception 'invalid_course_accepted';
    exception when invalid_parameter_value then assert sqlerrm = 'invalid_course';
    end;
  end loop;
  assert not has_table_privilege('authenticated', 'public.courses', 'INSERT,UPDATE,DELETE');
  assert not has_function_privilege('anon', 'public.save_course(uuid,integer,jsonb)', 'EXECUTE');
  begin
    update public.courses set document = course_document where id = course_id;
    raise exception 'direct_course_update_accepted';
  exception when insufficient_privilege then null;
  end;

  foreach bad_document in array array[
    jsonb_set(document, '{played_on}', '"2026-02-30"'),
    jsonb_set(document, '{played_on}', '"2026-11-01T01:00:00Z"'),
    jsonb_set(document, '{created_at}', '"not-a-date"'),
    jsonb_set(document, '{created_at}', '"2026-11-01T01:00:00"')
  ] loop
    begin
      perform public.submit_round(bad_document);
      raise exception 'invalid_round_date_accepted';
    exception when invalid_parameter_value then null;
    end;
  end loop;
  first_result := public.submit_round(document);
  retry_result := public.submit_round(document);
  target_upload := (first_result->>'upload_id')::uuid;
  assert first_result->>'state' = 'pending';
  assert first_result->'dispatch_needed' = 'true'::jsonb;
  assert retry_result->>'upload_id' = first_result->>'upload_id';
  assert retry_result->'duplicate' = 'true'::jsonb;
  assert retry_result->'dispatch_needed' = 'false'::jsonb;
  assert (select played_on = date '2026-11-01' and created_at = timestamptz '2026-11-01T01:00:00Z'
    from public.round_uploads where id = target_upload);

  begin
    perform public.submit_round(jsonb_set(jsonb_set(document, '{revision}', '2'), '{created_at}', '"2026-11-02T01:00:00Z"'));
    raise exception 'changed_creation_time_accepted';
  exception when invalid_parameter_value then assert sqlerrm = 'created_at_conflict';
  end;

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
  assert (select count(*) from public.courses) = 0;
  assert (select count(*) from public.round_uploads) = 0;
  assert (select count(*) from public.latest_round_status) = 0;
  perform public.save_course(course_id, 1, course_document);
  assert (select revision from public.courses where id = course_id) = 1;
  begin
    execute 'set local role anon';
    perform count(*) from public.rounds;
    raise exception 'anonymous_read_accepted';
  exception when insufficient_privilege then null;
  end;

  execute 'set local role round_log_worker';
  assert (select not rolbypassrls from pg_roles where rolname = 'round_log_worker');
  insert into public.rounds (user_id, id, source_upload_id, revision, transform_version, played_on, round_type,
    status, planned_holes, course_id, course_name, course_location, distance_unit, tee_id, tee_name, course_rating, slope_rating, created_at)
  values (owner_id, target_round_id, target_upload, 1, 1, '2026-11-01', 'practice', 'completed', 9,
    course_id, 'Sample Links', 'Test course', 'yd', tee_id, 'White', 35.4, 120, '2026-11-01T01:00:00Z');
  insert into public.hole_results (user_id, round_id, number, par, stroke_index, distance_m, strokes, mode)
  select owner_id, target_round_id, n, 4, n, 365.7600, 5, 'zen' from generate_series(1, 9) n;
  begin
    insert into public.hole_results (user_id, round_id, number, par, stroke_index, distance_m, strokes, mode, tee_x)
    values (owner_id, target_round_id, 10, 4, 10, 365.76, 5, 'standard', 0.5);
    raise exception 'unpaired_tee_coordinate_accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.hole_results (user_id, round_id, number, par, stroke_index, distance_m, strokes, mode, approach_y)
    values (owner_id, target_round_id, 10, 4, 10, 365.76, 5, 'standard', 0.5);
    raise exception 'unpaired_approach_coordinate_accepted';
  exception when check_violation then null;
  end;
  update private.processing_jobs set state = 'processed' where source_upload_id = target_upload;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  assert (select revision from public.courses where id = course_id) = 2;
  perform public.save_course(course_id, 3, jsonb_set(course_document, '{archived}', 'true'));
  assert (select course_name = 'Sample Links' and course_rating = 35.4 and slope_rating = 120
    from public.rounds where id = target_round_id);
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

  perform public.submit_round(jsonb_set(document, '{revision}', '4'));
  perform public.submit_round(jsonb_set(document, '{revision}', '3'));
  execute 'reset role';
  update public.round_uploads set received_at = now() + interval '1 hour'
  where user_id = owner_id and round_id = target_round_id and revision = 3;
  execute 'set local role authenticated';
  assert (select revision from public.latest_round_status) = 4;

  perform set_config('request.jwt.claim.sub', window_owner_id::text, true);
  for window_index in 1..21 loop
    window_round_id := gen_random_uuid();
    if window_index = 1 then oldest_round_id := window_round_id; end if;
    if window_index = 21 then pending_round_id := window_round_id; end if;
    window_document := jsonb_set(jsonb_set(jsonb_set(document, '{round_id}', to_jsonb(window_round_id)),
      '{played_on}', to_jsonb(to_char(date '2026-10-01' + (window_index - 1), 'YYYY-MM-DD'))),
      '{created_at}', '"2026-10-01T01:00:00Z"');
    first_result := public.submit_round(window_document);
    window_upload := (first_result->>'upload_id')::uuid;
    if window_index <= 20 then
      execute 'set local role round_log_worker';
      insert into public.rounds (user_id, id, source_upload_id, revision, transform_version, played_on, round_type,
        status, planned_holes, course_id, course_name, distance_unit, tee_id, tee_name, created_at)
      values (window_owner_id, window_round_id, window_upload, 1, 1, date '2026-10-01' + (window_index - 1), 'practice',
        'completed', 9, course_id, 'Sample Links', 'yd', tee_id, 'White', '2026-10-01T01:00:00Z');
      insert into public.hole_results (user_id, round_id, number, par, stroke_index, distance_m, strokes, mode)
      select window_owner_id, window_round_id, h, 4, h, 365.76, 5, 'zen' from generate_series(1, 9) h;
      update private.processing_jobs set state = 'processed' where source_upload_id = window_upload;
      execute 'set local role authenticated';
    end if;
  end loop;
  assert (select count(*) from public.round_summaries) = 20;
  assert (select count(*) from public.latest_twenty_rounds) = 19;
  assert not exists (select 1 from public.latest_twenty_rounds where id in (oldest_round_id, pending_round_id));
  assert (select round_sample from public.latest_twenty_metrics) = 19;
end;
$$;

rollback;
