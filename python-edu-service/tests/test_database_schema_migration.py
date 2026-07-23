"""SQLite 旧教务库升级回归测试。"""
import sqlite3

import pytest
from sqlalchemy import inspect
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

import models.database as database


@pytest.mark.asyncio
async def test_init_db_upgrades_existing_sqlite_edu_users_table(tmp_path, monkeypatch):
    db_path = tmp_path / "legacy-edu.db"
    connection = sqlite3.connect(db_path)
    connection.execute(
        """
        CREATE TABLE edu_users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id VARCHAR(64) NOT NULL UNIQUE,
            student_id VARCHAR(20) NOT NULL,
            name VARCHAR(50),
            encrypted_password TEXT,
            raw_password TEXT,
            cookie TEXT,
            grade VARCHAR(20),
            college VARCHAR(100),
            major VARCHAR(100),
            bound BOOLEAN DEFAULT 0,
            created_at DATETIME,
            updated_at DATETIME
        )
        """
    )
    connection.execute(
        "INSERT INTO edu_users (user_id, student_id, bound) VALUES (?, ?, ?)",
        ("u1", "2026000001", 1),
    )
    connection.commit()
    connection.close()

    engine = create_async_engine(f"sqlite+aiosqlite:///{db_path}")
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    monkeypatch.setattr(database, "engine", engine)
    monkeypatch.setattr(database, "AsyncSessionLocal", session_factory)

    try:
        await database.init_db()
        async with engine.connect() as conn:
            columns = await conn.run_sync(
                lambda sync_conn: {
                    column["name"]
                    for column in inspect(sync_conn).get_columns("edu_users")
                }
            )
        assert {
            "authorized",
            "session_state",
            "auto_relogin",
            "authorized_at",
            "logged_out_at",
            "revoked_at",
            "credential_generation",
        }.issubset(columns)
        # 旧表本身没有 UNIQUE，迁移后必须由命名索引阻止重复学号。
        with pytest.raises(sqlite3.IntegrityError):
            with sqlite3.connect(db_path) as verification_connection:
                verification_connection.execute(
                    "INSERT INTO edu_users (user_id, student_id) VALUES (?, ?)",
                    ("u2", "2026000001"),
                )
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_init_db_revokes_legacy_raw_password_records(tmp_path, monkeypatch):
    db_path = tmp_path / "legacy-raw-password.db"
    connection = sqlite3.connect(db_path)
    connection.execute(
        """
        CREATE TABLE edu_users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id VARCHAR(64) NOT NULL UNIQUE,
            student_id VARCHAR(20) NOT NULL,
            name VARCHAR(50),
            encrypted_password TEXT,
            raw_password TEXT,
            cookie TEXT,
            grade VARCHAR(20),
            college VARCHAR(100),
            major VARCHAR(100),
            bound BOOLEAN DEFAULT 0,
            created_at DATETIME,
            updated_at DATETIME
        )
        """
    )
    connection.execute(
        """
        INSERT INTO edu_users (user_id, student_id, raw_password, cookie, bound)
        VALUES (?, ?, ?, ?, ?)
        """,
        ("u1", "2026000001", "legacy-password", "legacy-cookie", 1),
    )
    connection.commit()
    connection.close()

    engine = create_async_engine(f"sqlite+aiosqlite:///{db_path}")
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    monkeypatch.setattr(database, "engine", engine)
    monkeypatch.setattr(database, "AsyncSessionLocal", session_factory)

    try:
        await database.init_db()
        with sqlite3.connect(db_path) as verification_connection:
            row = verification_connection.execute(
                """
                SELECT raw_password, encrypted_password, cookie, bound, authorized,
                       session_state, auto_relogin, revoked_at
                FROM edu_users WHERE user_id = ?
                """,
                ("u1",),
            ).fetchone()
        assert row[:7] == (None, None, None, 0, 0, "revoked", 0)
        assert row[7] is not None
    finally:
        await engine.dispose()
