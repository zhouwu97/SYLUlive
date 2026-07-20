"""退役历史服务器课表缓存的清理逻辑。"""

from sqlalchemy import inspect, text
from sqlalchemy.ext.asyncio import AsyncSession


# 表名为固定白名单，不接受外部输入，避免动态 SQL 扩张。
_LEGACY_COURSE_CACHE_TABLES = ("courses_custom", "courses_raw")


async def clear_legacy_course_cache(session: AsyncSession) -> dict[str, int]:
    """删除已退役课表缓存表中的历史记录，缺失表按空表处理。"""
    connection = await session.connection()
    table_names = await connection.run_sync(
        lambda sync_connection: set(inspect(sync_connection).get_table_names())
    )
    deleted: dict[str, int] = {}
    for table_name in _LEGACY_COURSE_CACHE_TABLES:
        if table_name not in table_names:
            deleted[table_name] = 0
            continue
        result = await session.execute(text(f"DELETE FROM {table_name}"))
        deleted[table_name] = max(result.rowcount or 0, 0)
    await session.commit()
    return deleted
