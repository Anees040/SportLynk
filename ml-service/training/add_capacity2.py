import pandas as pd
from pathlib import Path

def add_more_intents_2():
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
            'note': 'Fix capacity 2'
        })
        counter += 1

    extra = [
        # create_team_help (needs more mix and ru)
        ("apni team banani hai", "create_team_help", "ru"),
        ("how do i start a team", "create_team_help", "en"),
        ("naya squad banana hai", "create_team_help", "mix"),
        
        # greeting
        ("hey man", "greeting", "en"),
        ("whatsup", "greeting", "en"),
        ("hola", "greeting", "en"),
        ("salam dosto", "greeting", "ru"),
        
        # wallet_balance
        ("mera kitna paisa hai", "wallet_balance", "ru"),
        ("check my wallet", "wallet_balance", "en"),
        ("paisa dikhao", "wallet_balance", "ru"),
        ("kitna bacha hai", "wallet_balance", "ru"),
        ("remaining cash", "wallet_balance", "en"),
        
        # contact_owner (just in case)
        ("owner se baat karni hai", "contact_owner", "ru"),
    ]
    
    for _ in range(5):
        for t, i, l in extra:
            add(t, i, l)
            
    new_df = pd.DataFrame(rows)
    cols = ['id', 'text', 'intent', 'lang', 'phenomena', 'note']
    new_df = new_df[cols]
    
    combined = pd.concat([df, new_df]).drop_duplicates(subset=['text'], keep='first')
    combined.to_csv(file_path, index=False)
    print(f"Added capacity fixes 2. Total rows now: {len(combined)}")

if __name__ == '__main__':
    add_more_intents_2()
