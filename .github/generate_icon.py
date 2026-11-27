import os
from PIL import Image

img_path = "assets/images/sadhu_founder.png"
if not os.path.exists(img_path):
    print("No founder image found; keeping default launcher icon.")
    raise SystemExit(0)

src = Image.open(img_path).convert("RGBA")
w, h = src.size
side = min(w, h)
left = max(0, min(w - side, int(w * 0.14)))
top = max(0, min(h - side, int(h * 0.04)))
sq = src.crop((left, top, left + side, top + side))

sizes = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
for folder, px in sizes.items():
    out_dir = os.path.join("android/app/src/main/res", folder)
    os.makedirs(out_dir, exist_ok=True)
    icon = sq.resize((px, px), Image.Resampling.LANCZOS)
    icon.save(os.path.join(out_dir, "ic_launcher.png"))
    icon.save(os.path.join(out_dir, "ic_launcher_round.png"))

print("Generated Sadhu AI launcher icons successfully.")
