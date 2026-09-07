import ssl

from services.crawler import ACADEMIC_TLS_CIPHER, _academic_tls_context


def test_academic_tls_context_adds_legacy_school_cipher_without_disabling_validation():
    context = _academic_tls_context()
    cipher_names = {cipher["name"] for cipher in context.get_ciphers()}

    assert ACADEMIC_TLS_CIPHER == "DEFAULT:AES256-SHA"
    assert "AES256-SHA" in cipher_names
    assert context.minimum_version == ssl.TLSVersion.TLSv1_2
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert context.check_hostname is True
