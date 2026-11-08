import hashlib
import ssl

import pytest

from services import crawler
from services.crawler import ACADEMIC_TLS_CIPHER, _academic_tls_context


def test_school_intermediate_does_not_replace_root_or_hostname_validation():
    context = _academic_tls_context()
    assert context.check_hostname is True
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert not context.verify_flags & ssl.VERIFY_X509_PARTIAL_CHAIN
    fingerprints = {
        hashlib.sha256(cert).hexdigest()
        for cert in context.get_ca_certs(binary_form=True)
    }
    assert "416a2c89515b8bc14e13677024e2a82e8b1b2f4117a88fd11b8bbd25d1a5c517" in fingerprints


@pytest.mark.asyncio
@pytest.mark.parametrize("proxy", [None, "http://127.0.0.1:18002"])
async def test_school_client_uses_configured_campus_proxy_with_verified_tls(monkeypatch, proxy):
    if proxy is None:
        monkeypatch.delenv("CAMPUS_CRAWLER_PROXY", raising=False)
    else:
        monkeypatch.setenv("CAMPUS_CRAWLER_PROXY", proxy)
    options = {}

    class Client:
        async def aclose(self):
            pass

    def create_client(**kwargs):
        options.update(kwargs)
        return Client()

    monkeypatch.setattr(crawler.httpx, "AsyncClient", create_client)
    async with crawler.EduCrawler():
        assert options["proxy"] == proxy
        assert options["follow_redirects"] is False
        assert options["verify"].check_hostname is True
        assert options["verify"].verify_mode == ssl.CERT_REQUIRED


def test_academic_tls_context_adds_legacy_school_cipher_without_disabling_validation():
    context = _academic_tls_context()
    cipher_names = {cipher["name"] for cipher in context.get_ciphers()}

    assert ACADEMIC_TLS_CIPHER == "DEFAULT:AES256-SHA"
    assert "AES256-SHA" in cipher_names
    assert context.minimum_version == ssl.TLSVersion.TLSv1_2
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert context.check_hostname is True
