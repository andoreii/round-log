"""Run against an administrator connection; all synthetic changes roll back."""

import copy
import json
import os
from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4


def check():
    import psycopg
    from psycopg.types.json import Jsonb
    from pipeline.process_rounds import process_one

    payload = json.loads((Path(__file__).parent / "fixtures/nine_holes.json").read_text())
    course = json.loads((Path(__file__).parent / "fixtures/course_nine_holes.json").read_text())
    user_id, other_id = uuid4(), uuid4()
    payload["round_id"] = str(uuid4())
    with psycopg.connect(os.environ["TEST_DATABASE_URL"], sslmode="require") as connection:
        try:
            connection.execute("insert into auth.users (id) values (%s), (%s)", (user_id, other_id))
            connection.execute("set local role authenticated")
            connection.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(user_id),))
            connection.execute("select public.save_course(%s, 1, %s)", (payload["course"]["id"], Jsonb(course)))
            first = connection.execute("select public.submit_round(%s)", (Jsonb(payload),)).fetchone()[0]
            retry = connection.execute("select public.submit_round(%s)", (Jsonb(payload),)).fetchone()[0]
            assert first["upload_id"] == retry["upload_id"]
            assert first["dispatch_needed"] and not retry["dispatch_needed"] and retry["duplicate"]
            conflicting = copy.deepcopy(payload)
            conflicting["notes"] = "A changed revision needs a new number"
            try:
                with connection.transaction():
                    connection.execute("select public.submit_round(%s)", (Jsonb(conflicting),))
            except psycopg.errors.InvalidParameterValue:
                pass
            else:
                raise AssertionError("conflicting_revision_accepted")
            connection.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(other_id),))
            assert connection.execute("select count(*) from public.round_uploads").fetchone()[0] == 0
            try:
                with connection.transaction():
                    connection.execute("set local role anon")
                    connection.execute("select * from public.latest_round_status")
            except psycopg.errors.InsufficientPrivilege:
                pass
            else:
                raise AssertionError("anonymous_read_accepted")
            connection.execute("set local role round_log_worker")
            # Existing pending jobs would change the target of this isolated check.
            count = connection.execute("select count(*) from private.processing_jobs where state = 'pending'").fetchone()[0]
            assert count == 1, "run this check before ingesting personal rounds"
            assert process_one(connection) == "processed"
            connection.execute("set local role authenticated")
            connection.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(user_id),))
            summary = connection.execute("select total_strokes, score_to_par, putting_sample, fairway_sample, approach_sample from public.round_summaries").fetchone()
            assert summary == (41, 5, 3, 2, 3), summary
            course["name"] = "Changed course template"
            course["tees"][0]["ratings"]["full"]["course_rating"] = 36.2
            connection.execute("select public.save_course(%s, 2, %s)", (payload["course"]["id"], Jsonb(course)))
            snapshot = connection.execute("""
                select course_name, tee_id, course_rating, slope_rating, transform_version
                from public.rounds where user_id = %s and id = %s
            """, (user_id, payload["round_id"])).fetchone()
            assert snapshot == ("Sample Links", UUID(payload["tee"]["id"]), Decimal("35.9"), 125, 2), snapshot
            assert connection.execute("""
                select tee_club, approach_club from public.hole_results
                where user_id = %s and round_id = %s and number = 2
            """, (user_id, payload["round_id"])).fetchone() == ("8i", "8i")
            payload["revision"] = 3
            payload["holes"][0]["strokes"] = 6
            connection.execute("select public.submit_round(%s)", (Jsonb(payload),))
            connection.execute("set local role round_log_worker")
            assert process_one(connection) == "processed"
            connection.execute("set local role authenticated")
            payload["revision"] = 2
            connection.execute("select public.submit_round(%s)", (Jsonb(payload),))
            connection.execute("set local role round_log_worker")
            assert process_one(connection) == "skipped"
            assert connection.execute("select revision from public.rounds where user_id = %s and id = %s", (user_id, payload["round_id"])).fetchone()[0] == 3
            connection.execute("set local role authenticated")
            payload["revision"] = 4
            payload["holes"][0]["putts"] = 100
            connection.execute("select public.submit_round(%s)", (Jsonb(payload),))
            connection.execute("set local role round_log_worker")
            assert process_one(connection) == "invalid"
            connection.execute("set local role authenticated")
            latest = connection.execute("select revision, state, error_code from public.latest_round_status").fetchone()
            assert latest == (4, "invalid", "inconsistent_strokes"), latest
            assert connection.execute("select revision from public.rounds").fetchone()[0] == 3
            assert connection.execute("select count(*) from public.latest_twenty_metrics").fetchone()[0] == 0
        finally:
            connection.rollback()
    print("database_checks_passed; synthetic changes rolled back")


if __name__ == "__main__":
    check()
