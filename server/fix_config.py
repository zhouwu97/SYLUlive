import os

with open('e:/AI/xynewui/server/internal/config/config.go', 'r', encoding='utf-8') as f:
    content = f.read()

replacement = """content, err := os.ReadFile(".env")
	if err != nil {
		content, err = os.ReadFile("/opt/shenliyuan/.env")
	}"""
content = content.replace('content, err := os.ReadFile("/opt/shenliyuan/.env")', replacement)

with open('e:/AI/xynewui/server/internal/config/config.go', 'w', encoding='utf-8') as f:
    f.write(content)
