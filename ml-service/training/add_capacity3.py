import pandas as pd
from pathlib import Path

def add_more_intents_3():
    file_path = Path('data/assistant/authored_intents.csv')
    df = pd.read_csv(file_path)
    
    ids = df['id'].dropna().astype(str)
    au_ids = ids[ids.str.startswith('au-')]
    max_id = au_ids.str.replace('au-', '').astype(int).max() if not au_ids.empty else 999
    
    counter = max_id + 1
    rows = []
    
    def add(text, intent, lang):
        nonlocal counter
        rows.append({
            'id': f"au-{counter}",
            'text': text,
            'intent': intent,
            'lang': lang,
            'phenomena': 'plain',
            'note': 'Fix capacity 3'
        })
        counter += 1

    extra = [
        # greeting
        ("namaste", "greeting", "ru"),
        ("wassup", "greeting", "en"),
        ("kya hal chal", "greeting", "ru"),
        ("kia hal chal", "greeting", "ru"),
        ("how are you doing", "greeting", "en"),
        ("yo", "greeting", "en"),
        ("hello world", "greeting", "en"),
        ("good day", "greeting", "en"),
        ("hi there", "greeting", "en"),
        ("hey buddy", "greeting", "en"),
    ]
    
    for _ in range(2):
        for t, i, l in extra:
            add(t, i, l)
            
    new_df = pd.DataFrame(rows)
    cols = ['id', 'text', 'intent', 'lang', 'phenomena', 'note']
    new_df = new_df[cols]
    
    combined = pd.concat([df, new_df]).drop_duplicates(subset=['text'], keep='first')
    combined.to_csv(file_path, index=False)
    print(f"Added capacity fixes 3. Total rows now: {len(combined)}")

if __name__ == '__main__':
    add_more_intents_3()
