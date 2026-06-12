import os

with open('e:/AI/xynewui/server/internal/handlers/auth.go', 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace('"math/rand"', '')

with open('e:/AI/xynewui/server/internal/handlers/auth.go', 'w', encoding='utf-8') as f:
    f.write(content)
