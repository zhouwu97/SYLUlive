import hashlib
import ssl

import certifi
import pytest

from services import crawler
from services.crawler import ACADEMIC_TLS_CIPHER, _academic_tls_context


def test_school_intermediate_does_not_replace_root_or_hostname_validation(monkeypatch):
    roots = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    roots.load_verify_locations(cafile=certifi.where())
    root_fingerprints = {
        hashlib.sha256(cert).hexdigest()
        for cert in roots.get_ca_certs(binary_form=True)
    }
    monkeypatch.setattr(crawler.ssl, "create_default_context", lambda: roots)
    context = _academic_tls_context()
    assert context.check_hostname is True
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert not context.verify_flags & ssl.VERIFY_X509_PARTIAL_CHAIN
    fingerprints = {
        hashlib.sha256(cert).hexdigest()
        for cert in context.get_ca_certs(binary_form=True)
    }
    assert root_fingerprints <= fingerprints
    assert {
        "d0b626c8ad93962296b3920106ed7fb3818fcb98e0b73e799141b42521335b0f",
        "ce0df856ea6cc0ebe068f55c4cc4de77def45cacb2d4e946d8ade706666f5887",
    } <= fingerprints


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


def test_erke_crawler_enables_tls_verification_with_webvpn_adapter(monkeypatch):
    import erke_crawler

    monkeypatch.setattr(erke_crawler.ddddocr, "DdddOcr", lambda **kwargs: object())
    instance = erke_crawler.SyluCrawler()
    assert instance.session.verify is True
    adapter = instance.session.get_adapter(f"{erke_crawler.SyluCrawler.VPN_BASE}/login")
    assert isinstance(adapter, erke_crawler._WebVpnTLSAdapter)
    ctx = adapter._ssl_context
    assert ctx.verify_mode == ssl.CERT_REQUIRED
    assert ctx.check_hostname is True
    assert ctx.minimum_version == ssl.TLSVersion.TLSv1_2
    assert not (ctx.verify_flags & ssl.VERIFY_X509_PARTIAL_CHAIN)
