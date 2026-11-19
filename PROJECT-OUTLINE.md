# Round Log

A personal iPhone golf journal for recording a round quickly, then exploring the results with Python and SQL.

## First delivery

1. Write this outline before building the foundation.
2. Copy the complete Setlog recreation, rename it, and preserve its current screens and appearance.
3. Create the public `andoreii/round-log` repository and activate the local Git checks.
4. Provision the free Supabase project in the Andrei organization, Tokyo region.
5. Build and verify raw ingestion, Python cleaning, clean tables, and SQL analytics with synthetic rounds.

The copied interface is a temporary starting point. Golf screens, branding, and the accuracy sheet come in a separate design pass. Existing simulated account actions must not change real cloud data.

## Platform and structure

- Native SwiftUI, portrait iPhone, iOS 26 or later; personal installation through Xcode.
- Reuse the existing controls, sheets, navigation, typography, border, motion, and accessibility behavior.
- One observable local store, atomic Codable files, one submission endpoint, one Python worker, and one PostgreSQL database.
- Keep course templates in one local file and rounds in separate documents under Application Support. Keep protected data outside the repository.
- Use standard libraries and native APIs first. Add no general-purpose framework or service without a concrete need.

## Course library

Manually create and edit courses with a name, location, nine or eighteen numbered holes, each hole's par and stroke index, and named tee sets with distances. Support yards and metres. Tee sets share pars and stroke indexes. Store optional course and slope ratings per tee, with separate full/front/back ratings where supplied. Stroke index means hole difficulty ordering; it is not the player's Handicap Index.

Keep the library available offline. Queue owner-scoped cloud backups when courses are created or edited, including courses never played. Course backup does not start round processing.

Starting a round copies the selected course, tee, units, hole numbers, pars, stroke indexes, and distances into that round. Later template edits cannot rewrite history. Used courses can be archived rather than removing their played snapshots.

## Round setup and lifecycle

Choose a course, played date, tee, round type (casual, competition, tournament, practice), a short manually entered weather note, notes, and initial recording mode. Select front nine, back nine, or eighteen holes as appropriate for the course.

Lifecycle: start, record, pause/resume, end, review, submit. Ending early creates a partial round. Blank holes remain unplayed. Only one active round needs a prominent Resume action; history can contain several saved drafts.

Save every edit locally. Require strokes only when marking a hole played. All other fields are optional and can be filled later. Total strokes include putts and penalty strokes; never add penalties to the total a second time.

Submission is explicit. Freeze the submitted revision and persist it before attempting a network request. Offline submissions wait for connectivity. Later edits save locally but require another Submit action. Background or foreground retries must never submit a draft or unreviewed correction.

## Recording modes

| Mode | Fields |
| --- | --- |
| Zen | Strokes only |
| Standard | Strokes, putts, tee result, approach result, penalty strokes |
| Detailed | Standard fields, tee club, approach club, approach distance and unit |

Switch modes anytime, including between holes. Hiding a field never clears its value. Preserve the mode recorded for each hole.

Zen uses black, white, and neutral surfaces. Hole navigation and scoring remain visible; weather, clubs, shot statistics, and notes do not compete with score entry. Exact layouts wait for the design pass.

Approach distance means distance before the shot intended to reach the green, rather than distance remaining immediately after the drive. Record one approach observation per hole; this is not a complete shot-by-shot tracker. On a par 3, the tee shot is also the approach, entered once and excluded from fairway statistics.

## Accuracy sheet

Use the supplied reference image when it arrives. The bottom sheet accepts a tap or continuous finger drag, previews the selected result, and commits the resulting location. Provide accessible named alternatives to the gesture.

Store a normalized selected point and its directional outcome. A grid point describes an estimate, not measured GPS position or physical miss distance. The reference image will settle zone boundaries and final visual treatment; backend fixtures use basic hit and directional-miss labels meanwhile.

## Screens to design next

- Recent rounds: Resume, Start Round, latest twenty rounds, starred rounds, and backup state.
- Courses: course list, course editor, hole pars/indexes, and tee distances.
- Setup: round details and initial mode.
- Hole recorder: score controls, mode switch, optional statistics, accuracy sheet, and hole navigation.
- Scorecard and review: hole-by-hole entries, totals, missing fields, partial-round state, and Submit.
- Round detail: summary, correction/resubmission, and starring.
- Trends: latest-twenty statistics with comparable round lengths and recorded-data coverage.
- Settings: units, cloud sign-in, course backup, and pending-submission recovery.

## Local retention and recovery

- Retain the twenty most recent finished rounds, ordered by played date and then creation time, plus all starred rounds.
- Protect active, unsubmitted, pending, and failed rounds from trimming. Storage may temporarily exceed twenty plus stars.
- Prune only unstarred history safely received and processed in the cloud. Never delete cloud history when trimming the phone.
- Older starred rounds stay available offline but do not expand the analytics window. Unstarring an older round makes it eligible for safe trimming.
- Supabase retains every submitted round. Older unstarred rounds are inspected through Supabase, without a separate in-app archive in the first version.
- Restore recent rounds, starred rounds, and course templates after authenticated setup. One phone is the writer; no multi-device merge system.
- Serialize local writes, use atomic replacement and file protection, preserve corrupt files, and report save errors. Do not replace unreadable real data with demo fixtures.

## Submission and processing

1. The phone saves a frozen round snapshot with a stable round ID, increasing revision, and payload version.
2. An authenticated Edge Function derives the owner from the verified session. It calls a transaction that saves the raw snapshot and its pending job together.
3. An identical retry returns the existing receipt. A different payload cannot reuse the same revision.
4. The function dispatches one fixed GitHub workflow on the main branch. No personal fields are sent as workflow inputs.
5. Python reads pending jobs, validates the snapshot, normalizes units, and loads typed round and hole facts in a transaction.
6. SQL views calculate statistics from clean facts. Raw submissions remain unchanged for traceability.
7. Compact job and run records expose processing state and safe error codes.

No daily or hourly schedule. Previously submitted work can retry on Submit, app foreground, or manual recovery. A failed dispatch leaves a durable pending job; it does not lose an accepted upload. A worker crash rolls its transaction back. Invalid data waits for a corrected submission. Old arrivals cannot overwrite newer processed revisions.

Show separate states for saved locally, uploaded/pending processing, processed, and needs correction. Uploaded does not mean analytical results are ready. Core phone summaries work offline from the same metric definitions.

## Database responsibilities

| Data | Purpose |
| --- | --- |
| Course templates | Owner-scoped reusable course backup |
| Raw round uploads | Immutable submitted JSON revisions and server receipts |
| Processing jobs | Durable pending, processed, or invalid state |
| Clean rounds and holes | Typed, validated current facts with source revision and transform version |
| Round preferences | Star state, independent of score resubmission |
| Run records and issues | Counts, processing version, and safe validation codes |
| SQL views | Owner-scoped status, summaries, and latest-twenty analytics |

Raw and clean tables live in the same Supabase PostgreSQL database. Python is the processor, not another permanent data store. PostgreSQL enforces keys, ownership relationships, allowed values, and uniqueness. Keep migrations in source control. See [the approved schema](SCHEMA.md) for table definitions and validation rules.

## Validation and analytics

Preserve unknown values as null. An explicit zero remains zero. Reject structurally invalid payloads, duplicate hole numbers, nonpositive strokes, negative counts, and known putts plus penalties exceeding strokes. Require all selected holes to have scores for a complete round; partial rounds need at least one scored hole.

Normalize yards and metres using the exact conversion of one yard to 0.9144 metres. Preserve the original value and unit in raw data. Do not clamp unusual scores, invent missing statistics, or treat an unrecorded shot as successful.

Calculate gross scores, score to par, score distribution, putting averages, three-putt frequency, fairway-hit rate, approach-hit rate, directional misses, penalty rates, and club/distance breakdowns where observations exist. Show recorded and eligible sample counts. Fairway denominators exclude par 3s. Separate nine-hole and eighteen-hole total-score comparisons; mark partial rounds and use per-hole measures where appropriate.

All app trend calculations use the latest twenty finished rounds, not twenty plus old stars. Do not label approach hits as greens in regulation. No strokes gained, carry distance, measured proximity, scrambling, net scores, or official handicap calculation without their required inputs.

## Security

- Email/password cloud sign-in, one personal account, public registration disabled. Store sessions in Keychain; do not put passwords in project files.
- Enable row-level security on exposed tables, grant only needed operations, and check both existing and replacement ownership on updates.
- Clients can submit their own raw data and read their own results. They cannot alter raw history, write clean facts, or control worker state.
- Keep processing internals outside the exposed API schema. Give the worker a restricted database role without schema-management privileges or an RLS bypass.
- Use owner-respecting views. Verify Edge requests server-side. Never accept repository, branch, workflow, or owner identity from a submission body.
- Keep dispatch credentials in server secrets and database credentials in repository secrets. Do not expose privileged keys in the phone app.
- Public workflow output contains counts and safe codes only. No personal payloads, notes, SQL parameters, credentials, real-data artifacts, or caches.
- The public repository contains source and synthetic fixtures only. Retain required third-party notices.

## Repository and maintenance

Use single-author commit messages without tool attribution. Local checks reject prohibited attribution in commit messages and staged first-party text, and reject staged files over 5 MiB. Hook definitions, lockfiles, binaries, and required third-party notices are excluded from prose checks. Activate the tracked hooks on each clone.

Keep this outline as the source of project decisions. Keep README focused on running the app and worker. Comments explain a reason the code cannot show. Avoid duplicate documents, generated reports, vendored dependencies, large samples, build outputs, and media captures. Commit lockfiles and only the dependencies required to run the app and pipeline.

## Verification and later work

Foundation checks: renamed app build and launch, hook acceptance/rejection, compact Python validation tests, transactional ingestion/retry checks, revision ordering, metric denominators, and anonymous/other-user denial. Use small fixtures and focused assertions rather than coverage targets or exhaustive suites.

After golf screens exist, verify offline relaunch, score persistence, mode switching, course snapshots, edit/submission races, starring, safe trimming, accessibility, Reduce Motion, and scoring on the actual iPhone.

The foundation does not claim the golf recording interface is built. Subsequent work replaces the temporary screens, adds protected local golf storage and sync, then connects the on-device summaries and retention rules.

Out of scope: public onboarding, App Store release, multiplayer, GPS, automatic weather, external dashboards, daily jobs, warehouses, orchestration frameworks, and a large test suite. Use free resources only; review any paid change before adding it.
