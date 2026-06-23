import sqlite3
conn = sqlite3.connect(r'C:\Users\bru\AppData\Local\Temp\s3immich.db')

# Check if local_asset_entity has any matching DSC files
names = ['DSC_0001.JPG', 'DSC_0004.JPG', 'DSC_0008.JPG', 'DSC_0011.JPG', 'DSC_0012.JPG', 'DSC_0428.JPG']

print("=== local_asset_entity matches ===")
for name in names:
    rows = conn.execute("SELECT id, name, created_at FROM local_asset_entity WHERE name = ?", (name,)).fetchall()
    if rows:
        for r in rows:
            print(f"  LOCAL: {r}")
    else:
        print(f"  {name}: no local match")

print()
print("=== remote_asset_entity dates ===")
for name in names:
    row = conn.execute(
        "SELECT name, id, local_date_time, created_at FROM remote_asset_entity WHERE name = ? AND id LIKE '2015/%'",
        (name,)
    ).fetchone()
    if row:
        print(f"  {row[0]}: id={row[1]}, local_dt={row[2]}, created_at={row[3]}")
