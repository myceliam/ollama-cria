"""Same shape as OWUI's utils/valves.py: _fernet() gives an object with
encrypt/decrypt, and tokens start with gAAAAA. Not real cryptography."""

import base64
import hashlib

from open_webui.env import WEBUI_SECRET_KEY


class InvalidToken(Exception):
    pass


class _FakeFernet:
    def __init__(self, key: str):
        self.pad = hashlib.sha256(key.encode()).digest()

    def _xor(self, data: bytes) -> bytes:
        return bytes(b ^ self.pad[i % len(self.pad)] for i, b in enumerate(data))

    def encrypt(self, data: bytes) -> bytes:
        body = self._xor(hashlib.sha256(data).digest()[:4] + data)
        return b'gAAAAA' + base64.urlsafe_b64encode(body).rstrip(b'=')

    def decrypt(self, token: bytes) -> bytes:
        if not token.startswith(b'gAAAAA'):
            raise InvalidToken()
        raw = token[6:]
        body = self._xor(base64.urlsafe_b64decode(raw + b'=' * (-len(raw) % 4)))
        if hashlib.sha256(body[4:]).digest()[:4] != body[:4]:
            raise InvalidToken()
        return body[4:]


def _fernet():
    return _FakeFernet(WEBUI_SECRET_KEY)
