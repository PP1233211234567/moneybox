"""Executable SQL transaction proof; the Godot SQLite adapter is still missing."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from contextlib import closing


SQL_PATH = Path(__file__).parent / "migrations" / "0001_snapshot_bridge.sql"
WORKSPACE = Path(__file__).resolve().parents[2]
TEST_TMP_ROOT = (WORKSPACE / "tests" / "tmp").resolve()
TEST_TMP_ROOT.relative_to(WORKSPACE)


def connect(path: Path, *, timeout: float = 0.0) -> sqlite3.Connection:
    connection = sqlite3.connect(path, timeout=timeout, isolation_level=None)
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA journal_mode=DELETE")
    connection.execute("PRAGMA synchronous=FULL")
    return connection


def apply_first_migration(connection: sqlite3.Connection) -> None:
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    sql = SQL_PATH.read_text(encoding="utf-8")
    checksum = hashlib.sha256(sql.encode("utf-8")).hexdigest()
    if version == 1:
        row = connection.execute(
            "SELECT sql_sha256 FROM schema_migrations WHERE version=1"
        ).fetchone()
        if row != (checksum,):
            raise ValueError("MIGRATION_CHECKSUM_MISMATCH")
        return
    if version != 0:
        raise ValueError("FUTURE_SCHEMA")
    existing = connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    if existing:
        raise ValueError("UNKNOWN_EXISTING_SCHEMA")
    connection.execute("BEGIN IMMEDIATE")
    try:
        statement = ""
        for line in sql.splitlines(keepends=True):
            statement += line
            if sqlite3.complete_statement(statement):
                connection.execute(statement)
                statement = ""
        if statement.strip():
            raise ValueError("INCOMPLETE_MIGRATION_SQL")
        connection.execute(
            "INSERT INTO schema_migrations(version, sql_sha256, applied_at_utc) "
            "VALUES(1, ?, '2026-09-27T00:00:00Z')",
            (checksum,),
        )
        connection.execute("PRAGMA user_version=1")
        connection.commit()
    except BaseException:
        connection.rollback()
        raise


def encoded(value: dict) -> tuple[str, str]:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return payload, hashlib.sha256(payload.encode("utf-8")).hexdigest()


def seed(connection: sqlite3.Connection) -> None:
    project, project_hash = encoded({"data_kind": "personal", "amount": "123.45"})
    display, display_hash = encoded({"snapshot_status": "CURRENT", "bean_count": 0})
    connection.execute("BEGIN IMMEDIATE")
    try:
        connection.execute(
            "INSERT INTO local_project VALUES(1, 0, 'personal', 2, ?, ?, '2026-09-27T00:00:00Z')",
            (project_hash, project),
        )
        connection.execute(
            "INSERT INTO published_display VALUES(1, 0, 1, ?, ?)",
            (display_hash, display),
        )
        connection.commit()
    except BaseException:
        connection.rollback()
        raise


def save(
    connection: sqlite3.Connection,
    expected_generation: int,
    project: dict,
    display: dict,
) -> str:
    connection.execute("BEGIN IMMEDIATE")
    try:
        current = connection.execute(
            "SELECT generation FROM local_project WHERE singleton=1"
        ).fetchone()[0]
        if current != expected_generation:
            connection.rollback()
            return "GENERATION_CONFLICT"
        project_json, project_hash = encoded(project)
        display_json, display_hash = encoded(display)
        connection.execute(
            "UPDATE local_project SET generation=?, project_sha256=?, project_json=?, "
            "updated_at_utc='2026-09-27T01:00:00Z' WHERE singleton=1",
            (current + 1, project_hash, project_json),
        )
        connection.execute(
            "UPDATE published_display SET generation=?, display_sha256=?, "
            "display_json=? WHERE singleton=1",
            (current + 1, display_hash, display_json),
        )
        connection.commit()
        return "SAVED"
    except BaseException:
        connection.rollback()
        raise


class SnapshotBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        TEST_TMP_ROOT.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT)
        self.path = Path(self.temporary.name) / "personal.sqlite3"
        self.first = connect(self.path)
        apply_first_migration(self.first)
        seed(self.first)

    def tearDown(self) -> None:
        self.first.close()
        self.temporary.cleanup()

    def test_schema_checksum_and_future_guard(self) -> None:
        apply_first_migration(self.first)
        self.assertEqual(self.first.execute("PRAGMA user_version").fetchone(), (1,))
        self.first.execute("UPDATE schema_migrations SET sql_sha256=? WHERE version=1", ("0" * 64,))
        with self.assertRaisesRegex(ValueError, "MIGRATION_CHECKSUM_MISMATCH"):
            apply_first_migration(self.first)
        self.first.execute("PRAGMA user_version=2")
        with self.assertRaisesRegex(ValueError, "FUTURE_SCHEMA"):
            apply_first_migration(self.first)

    def test_generation_conflict_and_decimal_string(self) -> None:
        second = connect(self.path)
        try:
            self.assertEqual(
                save(self.first, 0, {"amount": "123.456789012345678901"}, {"bean_count": 1}),
                "SAVED",
            )
            self.assertEqual(
                save(second, 0, {"amount": "999"}, {"bean_count": 999}),
                "GENERATION_CONFLICT",
            )
            row = second.execute(
                "SELECT p.generation, p.project_json, d.generation, d.display_json "
                "FROM local_project p JOIN published_display d ON p.singleton=d.singleton"
            ).fetchone()
            self.assertEqual((row[0], row[2]), (1, 1))
            self.assertEqual(json.loads(row[1])["amount"], "123.456789012345678901")
            self.assertEqual(json.loads(row[3])["bean_count"], 1)
        finally:
            second.close()

    def test_second_writer_cannot_pass_same_precommit_generation(self) -> None:
        second = connect(self.path)
        try:
            self.first.execute("BEGIN IMMEDIATE")
            with self.assertRaises(sqlite3.OperationalError):
                second.execute("BEGIN IMMEDIATE")
            self.first.execute(
                "UPDATE local_project SET generation=1 WHERE singleton=1"
            )
            self.first.execute(
                "UPDATE published_display SET generation=1 WHERE singleton=1"
            )
            self.first.commit()
            self.assertEqual(
                save(second, 0, {"amount": "stale"}, {"bean_count": 2}),
                "GENERATION_CONFLICT",
            )
        finally:
            second.close()

    def test_project_only_update_cannot_commit_and_backup_is_consistent(self) -> None:
        self.first.execute("BEGIN IMMEDIATE")
        self.first.execute("UPDATE local_project SET generation=1 WHERE singleton=1")
        with self.assertRaises(sqlite3.IntegrityError):
            self.first.commit()
        self.first.rollback()
        self.assertEqual(
            self.first.execute("SELECT generation FROM local_project").fetchone(), (0,)
        )
        backup_path = Path(self.temporary.name) / "consistent-copy.sqlite3"
        with closing(connect(backup_path)) as destination:
            self.first.backup(destination)
            self.assertEqual(
                destination.execute("SELECT generation FROM published_display").fetchone(),
                (0,),
            )


if __name__ == "__main__":
    unittest.main()
