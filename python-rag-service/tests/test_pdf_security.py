"""PDF 解析回归在子进程中运行，防止坏文件拖死整个测试进程。"""
import subprocess
import sys


def test_truncated_xref_without_trailer_terminates():
    # 覆盖上游 py-pdf/pypdf#4289 的 EOF 路径；子进程超时约束解析停滞。
    source = """
from io import BytesIO
from pypdf import PdfReader
from pypdf.errors import PdfReadError
data = b"%PDF-1.4\\nstartxref\\n28\\n%%EOF\\nxref\\n1 0\\naaa"
try:
    PdfReader(BytesIO(data))
except PdfReadError as error:
    assert "Xref parsing stuck" in str(error), str(error)
    print("rejected")
else:
    raise AssertionError("Incomplete xref was accepted")
"""
    result = subprocess.run(
        [sys.executable, "-c", source],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "rejected"
