"""Drain pending submissions without logging round contents."""

import os
import sys
from uuid import uuid4

from pipeline.transform import TRANSFORM_VERSION, ValidationError, transform


def process_one(connection):
    from psycopg import sql

    with connection.transaction():
        job = connection.execute("""
            select j.source_upload_id, j.user_id, u.round_id, u.revision, u.payload
            from private.processing_jobs j join public.round_uploads u
              on u.id = j.source_upload_id and u.user_id = j.user_id
            where j.state = 'pending' order by u.received_at, u.id
            limit 1 for update of j skip locked
        """).fetchone()
        if job is None:
            return None
        upload_id, user_id, round_id, revision, payload = job
        # Serialize revisions of the same round, including independent worker runs.
        connection.execute("select pg_advisory_xact_lock(hashtextextended(%s, 0))", (str(user_id) + str(round_id),))
        current = connection.execute(
            "select revision from public.rounds where user_id = %s and id = %s", (user_id, round_id)
        ).fetchone()
        if current is not None and current[0] >= revision:
            outcome, error = "skipped", None
        else:
            try:
                round_values, holes = transform(payload)
            except ValidationError as exc:
                outcome, error = "invalid", exc.code
            else:
                round_values.update(user_id=user_id, source_upload_id=upload_id)
                columns = list(round_values)
                assignments = [sql.SQL("{} = excluded.{}").format(sql.Identifier(c), sql.Identifier(c))
                               for c in columns if c not in ("user_id", "id", "created_at")]
                connection.execute(sql.SQL("""
                    insert into public.rounds ({})
                    values ({})
                    on conflict (user_id, id) do update set {}, processed_at = now()
                    where public.rounds.revision < excluded.revision
                """).format(sql.SQL(", ").join(map(sql.Identifier, columns)),
                             sql.SQL(", ").join(sql.Placeholder() for _ in columns), sql.SQL(", ").join(assignments)),
                                   tuple(round_values[c] for c in columns))
                connection.execute("delete from public.hole_results where user_id = %s and round_id = %s", (user_id, round_id))
                for hole in holes:
                    hole.update(user_id=user_id, round_id=round_id)
                columns = list(holes[0])
                statement = sql.SQL("insert into public.hole_results ({}) values ({})").format(
                    sql.SQL(", ").join(map(sql.Identifier, columns)),
                    sql.SQL(", ").join(sql.Placeholder() for _ in columns))
                with connection.cursor() as cursor:
                    cursor.executemany(statement, [tuple(h[c] for c in columns) for h in holes])
                outcome, error = "processed", None
        connection.execute("""
            update private.processing_jobs set state = %s, error_code = %s, updated_at = now()
            where source_upload_id = %s
        """, ("invalid" if outcome == "invalid" else "processed", error, upload_id))
        return outcome


def run(database_url):
    import psycopg

    run_id = uuid4()
    counts = {"processed": 0, "invalid": 0, "skipped": 0}
    with psycopg.connect(database_url, autocommit=True, connect_timeout=15, sslmode="require") as connection:
        connection.execute("set statement_timeout = '60s'")
        connection.execute("set lock_timeout = '15s'")
        connection.execute("insert into private.pipeline_runs (id, transform_version, status) values (%s, %s, 'running')",
                           (run_id, TRANSFORM_VERSION))
        try:
            while True:
                outcome = process_one(connection)
                if outcome is None:
                    break
                counts[outcome] += 1
        except Exception:
            connection.execute("""
                update private.pipeline_runs set finished_at = now(), status = 'failed', error_code = 'processing_failed',
                  processed_count = %s, invalid_count = %s, skipped_count = %s where id = %s
            """, (counts["processed"], counts["invalid"], counts["skipped"], run_id))
            raise
        connection.execute("""
            update private.pipeline_runs set finished_at = now(), status = 'succeeded',
              processed_count = %s, invalid_count = %s, skipped_count = %s where id = %s
        """, (counts["processed"], counts["invalid"], counts["skipped"], run_id))
    return counts


def main():
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("configuration_missing", file=sys.stderr)
        return 1
    try:
        counts = run(database_url)
    except Exception:
        # Driver errors may include submitted values or connection credentials.
        print("processing_failed; pending submissions can be retried", file=sys.stderr)
        return 1
    print("processed={processed} invalid={invalid} skipped={skipped}".format(**counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
