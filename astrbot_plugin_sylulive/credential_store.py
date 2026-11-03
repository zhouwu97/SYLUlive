import json
import keyring


class CredentialStore:
    """Use the OS credential vault. Headless systems without one stay memory-only."""

    def __init__(self, identity):
        self.identity = identity
        self.persistent = False
        # Do not silently accept an installed plaintext/third-party backend.
        self.secure = type(keyring.get_keyring()).__module__ in {
            "keyring.backends.Windows",
            "keyring.backends.macOS",
            "keyring.backends.SecretService",
            "keyring.backends.kwallet",
        }

    def load(self):
        if not self.secure:
            return None
        try:
            raw = keyring.get_password("sylulive-astrbot", self.identity)
            value = json.loads(raw) if raw else None
            if value is not None and (
                not isinstance(value, dict)
                or not all(
                    k in value
                    for k in ("access_token", "refresh_token", "expires_at", "scope")
                )
            ):
                return None
            self.persistent = True
            return value
        except Exception:
            return None

    def save(self, value):
        if not self.secure:
            return
        try:
            keyring.set_password("sylulive-astrbot", self.identity, json.dumps(value))
            self.persistent = True
        except Exception:
            self.persistent = False

    def delete(self):
        if not self.secure:
            return
        try:
            keyring.delete_password("sylulive-astrbot", self.identity)
        except keyring.errors.PasswordDeleteError:
            pass
        except Exception:
            # Fail visibly rather than claiming a local credential was removed.
            if self.persistent:
                raise RuntimeError(
                    "系统凭据库清理失败；请在 SYLUlive 官网撤销授权"
                ) from None
