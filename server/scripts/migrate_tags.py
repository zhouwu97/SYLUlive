import sqlite3

db = sqlite3.connect('E:/AI/xynewui/server/sqlite.db')
cursor = db.cursor()

cursor.execute("SELECT id, slug FROM water_sections")
sections = cursor.fetchall()
section_map = {row[1]: row[0] for row in sections}

print("Section Map:", section_map)

# competition
if 'competition' in section_map:
    comp_id = section_map['competition']
    cursor.execute("UPDATE water_section_tags SET is_enabled = 0 WHERE section_id = ? AND slug IN ('algorithm', 'modeling')", (comp_id,))
    # update sort_order just in case
    cursor.execute("UPDATE water_section_tags SET sort_order = 10 WHERE section_id = ? AND slug = 'notice'", (comp_id,))
    cursor.execute("UPDATE water_section_tags SET sort_order = 20 WHERE section_id = ? AND slug = 'team'", (comp_id,))
    cursor.execute("UPDATE water_section_tags SET sort_order = 30 WHERE section_id = ? AND slug = 'experience'", (comp_id,))

# campus_life
if 'campus_life' in section_map:
    clife_id = section_map['campus_life']
    cursor.execute("UPDATE water_section_tags SET is_enabled = 0 WHERE section_id = ? AND slug IN ('campus_card', 'snapshot')", (clife_id,))
    for slug, name, sort_order in [('daily', '日常', 10), ('dormitory', '宿舍', 20), ('canteen', '食堂', 30), ('campus_view', '校园见闻', 40), ('other', '其他', 50)]:
        cursor.execute("SELECT id FROM water_section_tags WHERE section_id = ? AND slug = ?", (clife_id, slug))
        res = cursor.fetchone()
        if res:
            cursor.execute("UPDATE water_section_tags SET is_enabled = 1, sort_order = ? WHERE id = ?", (sort_order, res[0]))
        else:
            cursor.execute("INSERT INTO water_section_tags (section_id, slug, name, description, sort_order, is_default, is_enabled) VALUES (?, ?, ?, '', ?, 1, 1)", (clife_id, slug, name, sort_order))

db.commit()
db.close()
print("Migration done.")
