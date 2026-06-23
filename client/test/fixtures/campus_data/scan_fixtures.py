#!/usr/bin/env python3
import sys, re
from pathlib import Path

SENSITIVE = [
    b"JSESSIONID",
    b"CASTGC",
    b"wengine_vpn_ticket",
    b"Authorization",
    b"Cookie:",
    b"ticket=",
    b"password=",
]
# Exclude the scan script itself and git history
def scan():
    failed = False
    for p in Path("fixtures").rglob("*"):
        if p.is_file() and p.name != "scan_fixtures.py":
            content = p.read_bytes()
            for s in SENSITIVE:
                if s in content:
                    print(f"SENSITIVE DATA FOUND in {p}: {s}")
                    failed = True
            # Regex for ID or phone
            # 10 digit ID
            if re.search(br"\b24\d{8}\b", content):
                print(f"SENSITIVE ID FOUND in {p}")
                failed = True
            # Phone number
            if re.search(br"\b1[3-9]\d{9}\b", content):
                print(f"SENSITIVE PHONE FOUND in {p}")
                failed = True
    if failed:
        sys.exit(1)
    print("Scan passed.")

if __name__ == "__main__":
    scan()
