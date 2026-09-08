from fastapi.testclient import TestClient
from main import create_app


def test_freeze_rejects_before_auth_and_body_parsing():
    client = TestClient(create_app(retired=False, frozen=True))
    for path in ('/api/edu/bind', '/api/edu/grades', '/api/edu/session/resume', '/api/edu/refresh_cookie', '/api/edu/pre_verify'):
        result = client.post(path, content=b'not-json')
        assert result.status_code == 410
        assert result.json()['code'] == 'SCHOOL_LEGACY_SECRETS_FROZEN'


def test_cleanup_reaches_original_authentication():
    client = TestClient(create_app(retired=False, frozen=True))
    for method, path in [('DELETE', '/api/edu/bind'), ('DELETE', '/api/edu/authorization'),
                         ('POST', '/api/edu/session/logout')]:
        assert client.request(method, path).status_code != 410


def test_explicit_compatibility_preserves_old_client_routes():
    client = TestClient(create_app(retired=False, frozen=False))
    for method, path in [('POST','/api/edu/pre_verify'), ('POST','/api/edu/bind'),
                         ('POST','/api/edu/session/resume'), ('GET','/api/edu/grades')]:
        response = client.request(method,path,content=b'not-json')
        assert response.status_code not in (404,410)
