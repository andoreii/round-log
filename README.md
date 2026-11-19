# Round Log

A personal iPhone golf journal with offline recording and Python/SQL round analytics.

The imported Setlog interface remains the design base. Golf models, protected local storage, cloud sync, and analytics are implemented; golf screens and their controls come next. See [the project outline](PROJECT-OUTLINE.md) for the full scope.

## iPhone app

Open `RoundLog.xcodeproj`, select the `RoundLog` scheme, and run an iPhone simulator on iOS 26 or later. Choose your development team for a physical device. Existing account and export screens are local demonstrations.

`GolfServices` owns the golf store and Supabase session. Course edits save and queue backups automatically. `GolfStore.freezeSubmission` persists an explicit submission before sending; retries use that frozen snapshot. Foreground and connectivity changes retry queued work. Later edits require another submission.

Golf files live under Application Support, with atomic writes and iOS file protection. Sessions live in Keychain. The store keeps recent twenty finished rounds plus stars, protects work awaiting backup, and restores missing recent history after sync. Offline summaries preserve unknown values and separate nine-hole, eighteen-hole, and partial rounds.

## Local checks

Activate the tracked hooks after cloning:

```sh
git config core.hooksPath .githooks
python3 -B .githooks/check.py --self-test
python3 -B -m unittest discover -s tests -p 'test_*.py'
```

Hooks check commit attribution, staged first-party text, and the 5 MiB file limit. They are local checks, not server enforcement. Keep generated output and personal data outside Git.

For native logic tests, replace `DEVICE_ID` with an available simulator:

```sh
xcodebuild -project RoundLog.xcodeproj -scheme RoundLog \
  -destination 'platform=iOS Simulator,id=DEVICE_ID' \
  -derivedDataPath /tmp/round-log-derived-data \
  -only-testing:RoundLogTests test CODE_SIGNING_ALLOWED=NO
```

## Submitted-round pipeline

1. An authenticated POST sends a frozen round revision to `submit-round`.
2. Supabase saves the original JSON and a pending job in one transaction.
3. The endpoint starts the main-branch `Process submitted rounds` workflow without personal inputs.
4. Python validates the submission, normalizes distances to metres, and writes clean round/hole tables.
5. Owner-scoped SQL views expose status, summaries, and latest-twenty statistics.

An identical retry reuses its receipt. A changed payload needs a new revision. Failed dispatch leaves the accepted upload pending. Invalid data keeps its raw copy and needs a corrected submission. No scheduled jobs run.

The payload example is `tests/fixtures/nine_holes.json`. It includes unknown fields, explicit zeros, shared par-3 shots, and mixed distance units. `created_at` is the original timezone-aware creation timestamp; corrections preserve it.

The approved table and field definitions are in [the database schema](SCHEMA.md). Course backups use `save_course(course_id, revision, document)`; example documents are `tests/fixtures/course_nine_holes.json` and `course_eighteen_holes.json`. Direct course writes are blocked. Each edit increases its revision; identical retries reuse the saved version.

Round snapshots include `course.hole_count`, `tee.id`, and optional scoped `tee.ratings`. Cleaning selects only the rating for the selected holes. `created_at` uses ISO 8601 with seconds, a timezone, and at most six fractional digits. Changing its original instant returns `created_at_conflict`; edits to round data require a new revision. Submission format is version 1; current transformation is version 2.

Supabase project: `joevrtazhvmhrdmxneow`, Tokyo. Endpoint:

```text
https://joevrtazhvmhrdmxneow.supabase.co/functions/v1/submit-round
```

Requests require a user access token and `Content-Type: application/json`. The endpoint accepts at most 64 KiB. Responses distinguish upload acceptance from processing and dispatch state.

## Configuration

- Supabase: public signups disabled; create the personal email/password account through secure setup.
- GitHub Actions secret `DATABASE_URL`: TLS connection for the restricted `round_log_worker` role, never the database administrator.
- Supabase secret `ROUND_LOG_GITHUB_TOKEN`: a fine-grained token limited to this repository with Actions write permission. Keep publishing credentials out of this secret.
- Supabase supplies the function's project URL and API key. The function authenticates each user and preserves caller ownership checks.

The worker runs with Python 3.12 in GitHub Actions. To run it locally, use Python 3.10 or later, install `pipeline/requirements.txt` in a virtual environment, and provide `DATABASE_URL` securely:

```sh
python -m pipeline.process_rounds
```

Run `tests/verify_database.sql` as the project administrator for rollback-only database checks. For the optional Python worker integration check, use `PYTHONPATH=. python tests/check_database.py` with a private administrator `TEST_DATABASE_URL`; synthetic changes roll back.

Database migrations are in `supabase/migrations`. The current CLI is 3.2.0; it targets local resources by default. Review the target before applying hosted changes.

The submission function's focused checks run with `deno task check` from `supabase/functions/submit-round` when Deno is installed.
