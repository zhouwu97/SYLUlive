import asyncio
import sys
import os

# 将项目根目录加入 sys.path 以便导入 models
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text
from config import DATABASE_URL
import datetime

async def migrate():
    print(f"Connecting to database at {DATABASE_URL}...")
    engine = create_async_engine(DATABASE_URL, echo=False)
    
    async with engine.begin() as conn:
        print("Checking if 'year' column exists in 'courses_custom'...")
        # For SQLite, we can use pragma table_info
        result = await conn.execute(text("PRAGMA table_info(courses_custom)"))
        columns = [row[1] for row in result.fetchall()]
        
        if "year" not in columns:
            print("Adding 'year' column...")
            await conn.execute(text("ALTER TABLE courses_custom ADD COLUMN year VARCHAR(10)"))
        else:
            print("'year' column already exists.")
            
        if "semester" not in columns:
            print("Adding 'semester' column...")
            await conn.execute(text("ALTER TABLE courses_custom ADD COLUMN semester INTEGER"))
        else:
            print("'semester' column already exists.")
            
        if "term_id" not in columns:
            print("Adding 'term_id' column...")
            await conn.execute(text("ALTER TABLE courses_custom ADD COLUMN term_id VARCHAR(32)"))
        else:
            print("'term_id' column already exists.")

        # Create indices
        try:
            await conn.execute(text("CREATE INDEX IF NOT EXISTS ix_courses_custom_year ON courses_custom (year)"))
            await conn.execute(text("CREATE INDEX IF NOT EXISTS ix_courses_custom_semester ON courses_custom (semester)"))
            await conn.execute(text("CREATE INDEX IF NOT EXISTS ix_courses_custom_term_id ON courses_custom (term_id)"))
            print("Created indices.")
        except Exception as e:
            print(f"Note on indices (might exist): {e}")

        print("Backfilling 'year' and 'semester' from 'courses_raw'...")
        # SQLite update with join equivalent
        await conn.execute(text("""
            UPDATE courses_custom
            SET year = (SELECT year FROM courses_raw WHERE courses_raw.id = courses_custom.raw_id),
                semester = (SELECT semester FROM courses_raw WHERE courses_raw.id = courses_custom.raw_id)
            WHERE raw_id IS NOT NULL AND year IS NULL
        """))
        
        # Deduce fallback defaults for remaining nulls (e.g., custom manual courses)
        now = datetime.datetime.now()
        fallback_year = ""
        fallback_semester = 3
        
        if 2 <= now.month <= 7:
            fallback_year = f"{now.year - 1}"
            fallback_semester = 12
        elif now.month == 1:
            fallback_year = f"{now.year - 1}"
            fallback_semester = 3
        else:
            fallback_year = f"{now.year}"
            fallback_semester = 3
            
        print(f"Backfilling remaining nulls with default: year={fallback_year}, semester={fallback_semester}...")
        await conn.execute(text(f"""
            UPDATE courses_custom
            SET year = '{fallback_year}', semester = {fallback_semester}
            WHERE year IS NULL OR semester IS NULL
        """))
        
    print("Migration complete!")
    await engine.dispose()

if __name__ == "__main__":
    asyncio.run(migrate())
