"""教务内部服务的调用方认证与凭据加密。"""
import base64
import hmac

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import Header, HTTPException

from config import EDU_CREDENTIAL_ENCRYPTION_KEY, INTERNAL_SERVICE_TOKEN

_PREFIX = "aesgcm:v1:"


def require_internal_service(
    x_internal_service_token: str = Header(default=""),
) -> None:
    """只允许持有服务间密钥的 Go 服务调用教务业务接口。"""
    if not INTERNAL_SERVICE_TOKEN:
        raise HTTPException(status_code=503, detail="教务内部服务认证未配置")
    if not hmac.compare_digest(x_internal_service_token, INTERNAL_SERVICE_TOKEN):
        raise HTTPException(status_code=401, detail="教务内部服务认证失败")


def require_internal_user(
    x_internal_service_token: str = Header(default=""),
    x_internal_user_id: str = Header(default=""),
) -> str:
    require_internal_service(x_internal_service_token)
    user_id = x_internal_user_id.strip()
    if not user_id or len(user_id) > 64:
        raise HTTPException(status_code=401, detail="缺少有效的内部用户身份")
    return user_id


def _cipher() -> AESGCM:
    if not EDU_CREDENTIAL_ENCRYPTION_KEY:
        raise RuntimeError("未配置 EDU_CREDENTIAL_ENCRYPTION_KEY")
    try:
        key = base64.urlsafe_b64decode(EDU_CREDENTIAL_ENCRYPTION_KEY)
    except Exception as exc:
        raise RuntimeError("EDU_CREDENTIAL_ENCRYPTION_KEY 必须为 URL-safe Base64") from exc
    if len(key) != 32:
        raise RuntimeError("EDU_CREDENTIAL_ENCRYPTION_KEY 必须解码为 32 字节")
    return AESGCM(key)


def encrypt_credential(value: str) -> str:
    """以独立 AES-256-GCM 密钥加密教务密码或 Cookie。"""
    nonce = __import__("os").urandom(12)
    ciphertext = _cipher().encrypt(nonce, value.encode("utf-8"), None)
    return _PREFIX + base64.urlsafe_b64encode(nonce + ciphertext).decode("ascii")


def decrypt_credential(value: str | None) -> str:
    if not value or not value.startswith(_PREFIX):
        raise ValueError("凭据不存在或仍为旧格式，请重新绑定教务账号")
    payload = base64.urlsafe_b64decode(value[len(_PREFIX):])
    if len(payload) <= 12:
        raise ValueError("凭据密文格式错误")
    return _cipher().decrypt(payload[:12], payload[12:], None).decode("utf-8")


def is_encrypted_credential(value: str | None) -> bool:
    return bool(value and value.startswith(_PREFIX))
