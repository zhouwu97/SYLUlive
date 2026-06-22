import asyncio
import os
import sys

# Ensure we can import from the main project
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from models.database import engine
from services.credential_crypto import encrypt_credential, decrypt_credential

async def migrate_passwords():
    print("Starting password encryption migration...")

    from sqlalchemy import text

    try:
        async with engine.begin() as conn:
            table_result = await conn.execute(
                text("SELECT name FROM sqlite_master WHERE type='table' AND name='edu_users'")
            )
            if table_result.fetchone() is None:
                print("edu_users table does not exist. Migration not needed.")
                return

            pragma_result = await conn.execute(text("PRAGMA table_info(edu_users)"))
            columns = [row[1] for row in pragma_result.fetchall()]

            if "raw_password" not in columns:
                print("No raw_password column found in edu_users table. Migration not needed.")
                return

            if "encrypted_password" not in columns:
                print("Adding encrypted_password column to edu_users table...")
                await conn.execute(text("ALTER TABLE edu_users ADD COLUMN encrypted_password TEXT"))

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

                if enc_pwd and len(enc_pwd) > 0:
                    decrypted = decrypt_credential(enc_pwd)
                    if decrypted != raw_pwd:
                        raise ValueError(f"Existing encrypted password does not match raw password for user {user_id}")
                    await conn.execute(
                        text("UPDATE edu_users SET raw_password = '' WHERE id = :id"),
                        {"id": user_id}
                    )
                    continue

                try:
                    encrypted = encrypt_credential(raw_pwd)
                    decrypted = decrypt_credential(encrypted)
                    if decrypted != raw_pwd:
                        raise ValueError("Encrypted credential failed round-trip verification")
                except Exception as e:
                    print(f"Failed to encrypt password for user {user_id}. Rolling back.", file=sys.stderr)
                    raise e

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
