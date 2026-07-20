"""验证历史服务器课表缓存清理只作用于固定缓存表。"""

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from models import database
from services.course_cache_retirement import clear_legacy_course_cache


@pytest.mark.asyncio
async def test_clear_legacy_course_cache_deletes_only_legacy_course_tables():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as connection:
        await connection.execute(
            text("CREATE TABLE courses_raw (id INTEGER PRIMARY KEY, payload TEXT)")
        )
        await connection.execute(
            text(
                "CREATE TABLE courses_custom "
                "(id INTEGER PRIMARY KEY, raw_id INTEGER, payload TEXT)"
            )
        )
        await connection.execute(
            text("CREATE TABLE unrelated_records (id INTEGER PRIMARY KEY, payload TEXT)")
        )
        await connection.execute(
            text("INSERT INTO courses_raw (id, payload) VALUES (1, 'raw')")
        )
        await connection.execute(
            text("INSERT INTO courses_custom (id, raw_id, payload) VALUES (1, 1, 'custom')")
        )
        await connection.execute(
            text("INSERT INTO unrelated_records (id, payload) VALUES (1, 'keep')")
        )

    session_factory = async_sessionmaker(engine, class_=AsyncSession)
    async with session_factory() as session:
        deleted = await clear_legacy_course_cache(session)

    assert deleted == {"courses_custom": 1, "courses_raw": 1}
    async with session_factory() as session:
        raw_count = await session.scalar(text("SELECT COUNT(*) FROM courses_raw"))
        custom_count = await session.scalar(
            text("SELECT COUNT(*) FROM courses_custom")
        )
        unrelated_count = await session.scalar(
            text("SELECT COUNT(*) FROM unrelated_records")
        )

    assert raw_count == 0
    assert custom_count == 0
    assert unrelated_count == 1
    await engine.dispose()


@pytest.mark.asyncio
async def test_clear_legacy_course_cache_treats_missing_tables_as_empty():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    session_factory = async_sessionmaker(engine, class_=AsyncSession)

    async with session_factory() as session:
        deleted = await clear_legacy_course_cache(session)

    assert deleted == {"courses_custom": 0, "courses_raw": 0}
    await engine.dispose()


@pytest.mark.asyncio
async def test_init_db_clears_legacy_course_cache_without_legacy_credentials(monkeypatch):
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    monkeypatch.setattr(database, "engine", engine)
    monkeypatch.setattr(database, "AsyncSessionLocal", session_factory)

    async with engine.begin() as connection:
        await connection.execute(
            text("CREATE TABLE courses_raw (id INTEGER PRIMARY KEY, payload TEXT)")
        )
        await connection.execute(
            text("CREATE TABLE courses_custom (id INTEGER PRIMARY KEY, payload TEXT)")
        )
        await connection.execute(
            text("INSERT INTO courses_raw (id, payload) VALUES (1, 'raw')")
        )
        await connection.execute(
            text("INSERT INTO courses_custom (id, payload) VALUES (1, 'custom')")
        )

    await database.init_db()

    async with session_factory() as session:
        raw_count = await session.scalar(text("SELECT COUNT(*) FROM courses_raw"))
        custom_count = await session.scalar(
            text("SELECT COUNT(*) FROM courses_custom")
        )

    assert raw_count == 0
    assert custom_count == 0
    await engine.dispose()
