import os
from cryptography.fernet import Fernet, InvalidToken

_KEY = os.environ.get("EDU_CREDENTIAL_KEY")

if not _KEY:
    raise RuntimeError("EDU_CREDENTIAL_KEY is required but not set in environment variables.")

try:
    _fernet = Fernet(_KEY.encode('utf-8'))
except Exception as e:
    raise RuntimeError(f"Invalid EDU_CREDENTIAL_KEY: {e}")

_PREFIX = "fernet:v1:"

def encrypt_credential(password: str) -> str:
    """Encrypt a plaintext credential and return the ciphertext with version prefix."""
    if not password:
        return ""
    ciphertext = _fernet.encrypt(password.encode('utf-8')).decode('utf-8')
    return f"{_PREFIX}{ciphertext}"

def decrypt_credential(ciphertext: str) -> str:
    """Decrypt a versioned ciphertext credential back to plaintext."""
    if not ciphertext:
        return ""
    
    if not ciphertext.startswith(_PREFIX):
        raise ValueError(f"Ciphertext does not have the expected prefix {_PREFIX}")
    
    raw_ciphertext = ciphertext[len(_PREFIX):]
    try:
        plaintext = _fernet.decrypt(raw_ciphertext.encode('utf-8')).decode('utf-8')
        return plaintext
    except InvalidToken:
        raise ValueError("Decryption failed due to invalid token or corrupted ciphertext")
