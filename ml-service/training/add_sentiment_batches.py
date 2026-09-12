import os
import shutil

src_dir = r"C:\Users\Anees\.gemini\antigravity-ide\brain\7bb9fccb-0e2c-4e14-8f77-c9572c5e6a27\scratch"
dst_dir = r"d:\sportlynk\ml-service\data\sentiment"

files = [("sentiment_part2.csv", "authored_batch5.csv"), ("sentiment_part3.csv", "authored_batch6.csv")]

for src_name, dst_name in files:
    src_path = os.path.join(src_dir, src_name)
    dst_path = os.path.join(dst_dir, dst_name)
    
    with open(src_path, "r", encoding="utf-8") as f:
        content = f.read()
        
    # check if it already has a header
    if not content.startswith("text,label,lang"):
        content = "text,label,lang,aspect\n" + content
        
    with open(dst_path, "w", encoding="utf-8") as f:
        f.write(content)
    
    print(f"Written {dst_path}")
