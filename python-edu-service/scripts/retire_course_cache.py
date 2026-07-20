"""手动触发已退役服务器课表缓存清理。"""

import asyncio
import sys
from pathlib import Path


# 支持从 python-edu-service 目录直接执行本脚本。
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from models.database import AsyncSessionLocal
from services.course_cache_retirement import clear_legacy_course_cache


async def main() -> None:
    async with AsyncSessionLocal() as session:
        deleted = await clear_legacy_course_cache(session)
    print(f"已清理退役课表缓存: {deleted}")


if __name__ == "__main__":
    asyncio.run(main())
