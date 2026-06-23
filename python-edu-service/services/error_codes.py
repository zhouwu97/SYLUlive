from fastapi import HTTPException

EDU_NOT_BOUND = "EDU_NOT_BOUND"
EDU_CREDENTIAL_EXPIRED = "EDU_CREDENTIAL_EXPIRED"
INTERNAL_AUTH_FAILED = "INTERNAL_AUTH_FAILED"


def coded_http_exception(status_code: int, code: str, message: str) -> HTTPException:
    return HTTPException(
        status_code=status_code,
        detail={
            "code": code,
            "message": message,
        },
    )
