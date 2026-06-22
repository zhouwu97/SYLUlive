import asyncio
import os
import sys

# Ensure we can import from the main project
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sqlalchemy import select, update
from models.database import engine, EduUser
from services.credential_crypto import encrypt_credential

async def migrate_passwords():
    print("Starting password encryption migration...")
    
    async with engine.begin() as conn:
        # Check if raw_password column exists first (SQLite pragma or try-except)
        try:
            from sqlalchemy import text
            result = await conn.execute(text("SELECT id, raw_password FROM edu_users WHERE raw_password IS NOT NULL AND raw_password != ''"))
            rows = result.fetchall()
            
            if not rows:
                print("No raw passwords found to migrate.")
                return
            
            print(f"Found {len(rows)} users with raw passwords. Encrypting...")
            
            for row in rows:
                user_id = row[0]
                raw_pwd = row[1]
                
                encrypted = encrypt_credential(raw_pwd)
                
                await conn.execute(
                    text("UPDATE edu_users SET encrypted_password = :enc, raw_password = '' WHERE id = :id"),
                    {"enc": encrypted, "id": user_id}
                )
                
            print("Migration completed successfully.")
        except Exception as e:
            print(f"Migration error (column might not exist or other issue): {e}")

if __name__ == "__main__":
    asyncio.run(migrate_passwords())
