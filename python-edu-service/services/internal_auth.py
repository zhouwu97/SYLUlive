import os
import hmac
from typing import Annotated
from fastapi import Header, HTTPException

INTERNAL_SERVICE_KEY = os.environ.get("INTERNAL_SERVICE_KEY")
if not INTERNAL_SERVICE_KEY or INTERNAL_SERVICE_KEY == "dev_internal_key" or not INTERNAL_SERVICE_KEY.strip():
    raise RuntimeError("INTERNAL_SERVICE_KEY must be configured with a secure value in production!")

async def require_internal_service_key(
    x_internal_service_key: Annotated[str | None, Header()] = None,
) -> None:
    """Dependency to enforce internal service key validation."""
    if not x_internal_service_key:
        raise HTTPException(status_code=401, detail="Missing X-Internal-Service-Key")
        
    if not hmac.compare_digest(x_internal_service_key, INTERNAL_SERVICE_KEY):
        raise HTTPException(status_code=401, detail="Invalid X-Internal-Service-Key")
