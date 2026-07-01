"""pytest conftest — 将上级目录加入 sys.path，便于 `import sanitize_html`。"""
import sys
from pathlib import Path

PROBE_DIR = Path(__file__).resolve().parent.parent
if str(PROBE_DIR) not in sys.path:
    sys.path.insert(0, str(PROBE_DIR))
