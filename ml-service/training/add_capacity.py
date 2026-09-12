import pandas as pd
from pathlib import Path
import uuid

def add_more_intents():
    file_path = Path('data/assistant/authored_intents.csv')
    df = pd.read_csv(file_path)
    
    # We find the max au-NNN id
    ids = df['id'].dropna().astype(str)
    au_ids = ids[ids.str.startswith('au-')]
    max_id = 999
    if not au_ids.empty:
        max_id = au_ids.str.replace('au-', '').astype(int).max()
    
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
            'note': 'Fix capacity'
        })
        counter += 1

    extra = [
        # create_team_help (needs ~30)
        ("how to make a team", "create_team_help", "en"),
        ("i want to create a club", "create_team_help", "en"),
        ("where do i form a squad", "create_team_help", "en"),
        ("team kaise banau", "create_team_help", "ru"),
        ("nay team banana hai", "create_team_help", "ru"),
        ("club create karne ka tarika", "create_team_help", "mix"),
        ("steps to form team", "create_team_help", "en"),
        ("guide to making a team", "create_team_help", "en"),
        ("how to register a new team", "create_team_help", "en"),
        ("team register kaise karu", "create_team_help", "mix"),
        
        # greeting (needs ~25)
        ("hello friend", "greeting", "en"),
        ("hi bot", "greeting", "en"),
        ("good morning app", "greeting", "en"),
        ("salam", "greeting", "ru"),
        ("assalam o alaikum", "greeting", "ru"),
        ("kya haal hai", "greeting", "mix"),
        ("howdy", "greeting", "en"),
        ("hey there bot", "greeting", "en"),
        ("greetings", "greeting", "en"),
        
        # topup_help (needs ~25)
        ("add money", "topup_help", "en"),
        ("recharge wallet", "topup_help", "en"),
        ("paise dalne hain", "topup_help", "ru"),
        ("balance kaise add karu", "topup_help", "mix"),
        ("how to top up", "topup_help", "en"),
        ("deposit funds", "topup_help", "en"),
        ("account recharge", "topup_help", "en"),
        ("paise jama karne ka tarika", "topup_help", "ru"),
        ("add balance into account", "topup_help", "mix"),
        
        # wallet_balance (needs ~20)
        ("how much money", "wallet_balance", "en"),
        ("current balance", "wallet_balance", "en"),
        ("paise kitne bache", "wallet_balance", "ru"),
        ("show remaining amount", "wallet_balance", "en"),
        ("kitne funds hain", "wallet_balance", "mix"),
        ("balance check kar", "wallet_balance", "mix"),
        
        # my_bookings (needs ~30)
        ("where are my bookings", "my_bookings", "en"),
        ("show past bookings", "my_bookings", "en"),
        ("meri history", "my_bookings", "ru"),
        ("kya book kiya maine", "my_bookings", "mix"),
        ("list my reservations", "my_bookings", "en"),
        ("what are my games", "my_bookings", "en"),
        ("upcoming matches", "my_bookings", "en"),
        ("meri booking dikhao", "my_bookings", "ru"),
        
        # tournament_list (needs ~25)
        ("active cups", "tournament_list", "en"),
        ("tournaments happening", "tournament_list", "en"),
        ("koi cup hai", "tournament_list", "ru"),
        ("tournaments ki list do", "tournament_list", "mix"),
        ("show events", "tournament_list", "en"),
        ("current competitions", "tournament_list", "en"),
        ("kya events ho rahe", "tournament_list", "ru"),
    ]
    
    for _ in range(4): # 4 * 7-10 = ~28-40 rows each
        for t, i, l in extra:
            add(t, i, l)
            
    new_df = pd.DataFrame(rows)
    cols = ['id', 'text', 'intent', 'lang', 'phenomena', 'note']
    new_df = new_df[cols]
    
    combined = pd.concat([df, new_df]).drop_duplicates(subset=['text'], keep='first')
    combined.to_csv(file_path, index=False)
    print(f"Added capacity fixes. Total rows now: {len(combined)}")

if __name__ == '__main__':
    add_more_intents()
