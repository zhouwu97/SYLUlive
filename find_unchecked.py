import os
import re

handlers_dir = "server/internal/handlers"
unchecked = []

for filename in os.listdir(handlers_dir):
    if not filename.endswith(".go"):
        continue
    filepath = os.path.join(handlers_dir, filename)
    with open(filepath, "r", encoding="utf-8") as f:
        lines = f.readlines()
        
    for i, line in enumerate(lines):
        if ".First(" in line or ".Take(" in line:
            # Check if err is captured in the same line
            if "err :=" in line or "err =" in line or "Error !=" in line or "Error ==" in line:
                continue
            
            # Check if next line checks err
            if i + 1 < len(lines):
                next_line = lines[i+1]
                if "if err" in next_line or "err !=" in next_line:
                    continue
                    
            unchecked.append(f"{filename}:{i+1}: {line.strip()}")

for u in unchecked:
    print(u)
