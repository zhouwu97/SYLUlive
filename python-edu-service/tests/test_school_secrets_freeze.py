from fastapi.testclient import TestClient
from main import create_app


def test_freeze_rejects_before_auth_and_body_parsing():
    client = TestClient(create_app(retired=False, frozen=True))
    for path in ('/api/edu/bind', '/api/edu/grades', '/api/edu/session/resume', '/api/edu/refresh_cookie'):
        result = client.post(path, content=b'not-json')
        assert result.status_code == 410
        assert result.json()['code'] == 'SCHOOL_LEGACY_SECRETS_FROZEN'


def test_cleanup_and_preverify_reach_original_authentication():
    client = TestClient(create_app(retired=False, frozen=True))
    for method, path in [('DELETE', '/api/edu/bind'), ('DELETE', '/api/edu/authorization'),
                         ('POST', '/api/edu/session/logout'), ('POST', '/api/edu/pre_verify')]:
        assert client.request(method, path).status_code != 410
