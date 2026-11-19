-- The administrator may assume the restricted role for provisioning and verification.
grant round_log_worker to postgres;

create index processing_jobs_owner_source_idx
  on private.processing_jobs (user_id, source_upload_id);

revoke all on public.latest_round_status, public.latest_twenty_rounds, public.round_summaries,
  public.latest_twenty_metrics, public.latest_twenty_shots from authenticated;
grant select on public.latest_round_status, public.latest_twenty_rounds, public.round_summaries,
  public.latest_twenty_metrics, public.latest_twenty_shots to authenticated;
