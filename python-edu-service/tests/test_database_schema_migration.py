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
            student_id VARCHAR(20) NOT NULL UNIQUE,
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
    finally:
        await engine.dispose()
