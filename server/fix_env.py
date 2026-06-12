import re

with open('e:/AI/xynewui/server/internal/config/config.go', 'r', encoding='utf-8') as f:
    content = f.read()

replacement = """
		lines := strings.Split(string(content), "\\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				os.Setenv(strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]))
			}
		}
"""

content = re.sub(r'lines := strings\.Split.*?\}\s*\}', replacement.strip(), content, flags=re.DOTALL)

with open('e:/AI/xynewui/server/internal/config/config.go', 'w', encoding='utf-8') as f:
    f.write(content)
