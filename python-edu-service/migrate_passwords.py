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
    
    # We should use an AsyncSession to handle commits/rollbacks properly
    from sqlalchemy.ext.asyncio import AsyncSession
    from sqlalchemy import text
    
    try:
        async with engine.begin() as conn:
            result = await conn.execute(text("SELECT id, raw_password, encrypted_password FROM edu_users WHERE raw_password IS NOT NULL AND raw_password != ''"))
            rows = result.fetchall()
            
            if not rows:
                print("No raw passwords found to migrate.")
                return
            
            print(f"Found {len(rows)} users with raw passwords. Encrypting...")
            
            for row in rows:
                user_id = row[0]
                raw_pwd = row[1]
                enc_pwd = row[2]
                
                # Make sure it's idempotent
                if enc_pwd and len(enc_pwd) > 0:
                    continue
                
                encrypted = encrypt_credential(raw_pwd)
                
                await conn.execute(
                    text("UPDATE edu_users SET encrypted_password = :enc, raw_password = '' WHERE id = :id"),
                    {"enc": encrypted, "id": user_id}
                )
            
            print("Migration completed successfully.")
    except Exception as e:
        print(f"Migration error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    try:
        asyncio.run(migrate_passwords())
    except KeyboardInterrupt:
        sys.exit(1)
