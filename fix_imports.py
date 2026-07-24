from pathlib import Path

roots = [
    Path("client/lib/screens"),
    Path("client/test"),
]

changed = []

for root in roots:
    for path in root.rglob("*.dart"):
        raw = path.read_bytes()
        text = raw.decode("utf-8")

        lines = text.splitlines(keepends=True)
        new_lines = []

        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith("import ") and "main.dart" in line:
                line = line.replace("main.dart", "app_bootstrap.dart")
            new_lines.append(line)

        new_text = "".join(new_lines)

        if new_text != text:
            path.write_bytes(new_text.encode("utf-8"))
            changed.append(str(path))

print("\n".join(changed))
