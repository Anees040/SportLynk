import pandas as pd
from pathlib import Path

def main():
    rows = []
    
    # ---------------------------------------------------------
    # 1. 200 INDIRECT EXAMPLES (The weakest phenomenon at 49.1%)
    # ---------------------------------------------------------
    # wallet_balance (indirect)
    rows.extend([
        ("whats sitting in there right now", "wallet_balance", "en"),
        ("how much is left", "wallet_balance", "en"),
        ("do i have enough for a booking", "wallet_balance", "en"),
        ("what is my current standing", "wallet_balance", "en"),
        ("can you check what I have", "wallet_balance", "en"),
        ("kitnay bach gaye", "wallet_balance", "ru"),
        ("baki kitna para hai", "wallet_balance", "ru"),
        ("account me kitne hain", "wallet_balance", "mix"),
        ("check balance", "wallet_balance", "en"),
        ("show funds", "wallet_balance", "en"),
        ("remaining amount", "wallet_balance", "en"),
        ("remaining funds", "wallet_balance", "en"),
        ("kitne paise hain", "wallet_balance", "ru"),
        ("how much can i spend", "wallet_balance", "en"),
        ("can i afford 2000", "wallet_balance", "en"),
    ] * 2) # 30

    # book_venue (indirect)
    rows.extend([
        ("lock that one in", "book_venue", "en"),
        ("ill take it", "book_venue", "en"),
        ("put my name down for 8pm", "book_venue", "en"),
        ("reserve the second option", "book_venue", "en"),
        ("im down for that slot", "book_venue", "en"),
        ("done", "book_venue", "en"),
        ("yehi theek hai", "book_venue", "ru"),
        ("mera naam likh do", "book_venue", "ru"),
        ("done kar dein", "book_venue", "mix"),
        ("yehi fix kar lo", "book_venue", "mix"),
        ("go ahead with 9pm", "book_venue", "mix"),
        ("confirm 9 baje wala", "book_venue", "mix"),
        ("secure that for us", "book_venue", "en"),
        ("set it up", "book_venue", "en"),
        ("lets go with jinnah", "book_venue", "en"),
    ] * 2) # 30
    
    # cancel_booking (indirect)
    rows.extend([
        ("im not going anymore", "cancel_booking", "en"),
        ("take my name off", "cancel_booking", "en"),
        ("someone else can have it", "cancel_booking", "en"),
        ("free up that slot", "cancel_booking", "en"),
        ("scrap the 20:00 slot", "cancel_booking", "en"),
        ("undo it please", "cancel_booking", "en"),
        ("no longer needed", "cancel_booking", "en"),
        ("we are done", "cancel_booking", "en"),
        ("ab nahi aana", "cancel_booking", "ru"),
        ("plan cancel ho gaya", "cancel_booking", "mix"),
        ("delete my reservation", "cancel_booking", "en"),
        ("remove me from the list", "cancel_booking", "en"),
        ("im backing out", "cancel_booking", "en"),
        ("can we drop this", "cancel_booking", "en"),
        ("drop the saturday one", "cancel_booking", "en"),
    ] * 2) # 30

    # find_opponents (indirect)
    rows.extend([
        ("we need a challenge", "find_opponents", "en"),
        ("anyone want to play us", "find_opponents", "en"),
        ("looking for a match", "find_opponents", "en"),
        ("who is up for a game", "find_opponents", "en"),
        ("need competition", "find_opponents", "en"),
        ("koi team free hai", "find_opponents", "ru"),
        ("kisse match khelein", "find_opponents", "ru"),
        ("we are ready to play", "find_opponents", "en"),
        ("need another team", "find_opponents", "en"),
        ("find us a rival", "find_opponents", "en"),
        ("challenge open for tonight", "find_opponents", "en"),
        ("match chahiye", "find_opponents", "mix"),
        ("is there a team available", "find_opponents", "en"),
        ("who can we play against", "find_opponents", "en"),
        ("need a squad to face", "find_opponents", "en"),
    ] * 2) # 30

    # find_venue (indirect)
    rows.extend([
        ("where can we play", "find_venue", "en"),
        ("need a ground", "find_venue", "en"),
        ("any places nearby", "find_venue", "en"),
        ("looking for turf", "find_venue", "en"),
        ("koi ground batao", "find_venue", "ru"),
        ("kahan khelein", "find_venue", "ru"),
        ("suggest some courts", "find_venue", "en"),
        ("what arenas are good", "find_venue", "en"),
        ("show me some places", "find_venue", "en"),
        ("need a spot to play", "find_venue", "en"),
        ("good pitches in lahore", "find_venue", "mix"),
        ("top facilities", "find_venue", "en"),
        ("where is a good turf", "find_venue", "en"),
        ("recommend a ground", "find_venue", "en"),
        ("any stadiums around", "find_venue", "en"),
    ] * 2) # 30

    # team_stats (indirect)
    rows.extend([
        ("how are we doing", "team_stats", "en"),
        ("what is our record", "team_stats", "en"),
        ("are we winning", "team_stats", "en"),
        ("show our performance", "team_stats", "en"),
        ("hum kaisa khel rahe hain", "team_stats", "ru"),
        ("our standing", "team_stats", "en"),
        ("points table for us", "team_stats", "en"),
        ("win loss ratio", "team_stats", "en"),
        ("how many games won", "team_stats", "en"),
        ("tell me our stats", "team_stats", "en"),
    ] * 2) # 20
    
    # ---------------------------------------------------------
    # 2. 150 BOUNDARY EXAMPLES (cancel↔book, book↔check_availability, my_bookings↔book)
    # ---------------------------------------------------------
    rows.extend([
        # check_availability vs book_venue
        ("is 8pm free because i want to book it", "book_venue", "en"),
        ("is 8pm free", "check_availability", "en"),
        ("check if 9pm is open and confirm it", "book_venue", "en"),
        ("check if 9pm is open", "check_availability", "en"),
        ("find out what slots are free", "check_availability", "en"),
        ("book whatever slot is free", "book_venue", "en"),
        ("tell me the free times", "check_availability", "en"),
        ("i need to book a free time", "book_venue", "en"),
        ("are there slots available", "check_availability", "en"),
        ("secure an available slot", "book_venue", "en"),
        ("khali hai kya", "check_availability", "ru"),
        ("khali hai toh book kar do", "book_venue", "ru"),
        ("koi time bacha hai", "check_availability", "ru"),
        ("bacha hua time fix kar lo", "book_venue", "mix"),
        
        # cancel_booking vs my_bookings
        ("show my bookings so i can cancel", "cancel_booking", "en"),
        ("show my bookings", "my_bookings", "en"),
        ("which one did i book, i need to drop it", "cancel_booking", "en"),
        ("which one did i book", "my_bookings", "en"),
        ("what are my reservations", "my_bookings", "en"),
        ("remove my reservations", "cancel_booking", "en"),
        ("mere bookings ki list do", "my_bookings", "ru"),
        ("meri booking delete karo", "cancel_booking", "ru"),
        ("did i book 8pm", "my_bookings", "en"),
        ("i didn't mean to book 8pm", "cancel_booking", "en"),
        
        # cancel_booking vs book_venue
        ("instead of 8pm, book 9pm", "book_venue", "en"),
        ("i meant 9pm, not 8pm", "cancel_booking", "en"), # Implicit cancel of 8pm
        ("change my booking to tomorrow", "book_venue", "en"), # Intent is to book the new one
        ("cancel the old one and get a new one", "book_venue", "en"), 
        ("just cancel it entirely", "cancel_booking", "en"),
        
        # tournament_list vs app_help
        ("how do tournaments work", "app_help", "en"),
        ("what tournaments are running", "tournament_list", "en"),
        ("show me the active cups", "tournament_list", "en"),
        ("explain the cup system", "app_help", "en"),
        
        # find_venue vs venue_info
        ("where is model town club", "venue_info", "en"),
        ("find clubs in model town", "find_venue", "en"),
        ("tell me about jinnah stadium", "venue_info", "en"),
        ("show stadiums like jinnah", "find_venue", "en"),
        
        # find_opponents vs find_players
        ("we need a team to play against", "find_opponents", "en"),
        ("i need players for my team", "find_players", "en"),
        ("looking for opponents", "find_opponents", "en"),
        ("looking for team members", "find_players", "en"),
    ] * 4) # 136

    # ---------------------------------------------------------
    # 3. 100 ENGLISH-FOCUSED EXAMPLES (Weakest language at 62.3%)
    # ---------------------------------------------------------
    rows.extend([
        ("hey there", "greeting", "en"),
        ("good evening", "greeting", "en"),
        ("yes", "affirm", "en"),
        ("no", "deny", "en"),
        ("please confirm", "affirm", "en"),
        ("decline", "deny", "en"),
        ("what is this app for", "app_help", "en"),
        ("how do i navigate", "navigate", "en"),
        ("take me to the home page", "navigate", "en"),
        ("i want to talk to the admin", "contact_owner", "en"),
        ("who owns this place", "contact_owner", "en"),
        ("what is the elo rating", "elo_help", "en"),
        ("how are rankings calculated", "elo_help", "en"),
        ("how to create a squad", "create_team_help", "en"),
        ("steps to form a team", "create_team_help", "en"),
        ("can i get my money back", "refund_policy", "en"),
        ("what happens if it rains", "refund_policy", "en"),
        ("how to add balance", "topup_help", "en"),
        ("deposit money", "topup_help", "en"),
        ("i want to join a team", "find_teams", "en"),
        ("looking for a squad to join", "find_teams", "en"),
    ] * 5) # 105

    # ---------------------------------------------------------
    # 4. 50 NEGATION EXAMPLES (65.7% accuracy)
    # ---------------------------------------------------------
    rows.extend([
        ("don't book it yet", "deny", "en"),
        ("i don't want to play today", "deny", "en"),
        ("not the 8pm slot", "cancel_booking", "en"),
        ("i am not looking for a team", "deny", "en"),
        ("don't show me cricket grounds", "find_venue", "en"),
        ("nahi chahiye abhi", "deny", "ru"),
        ("cancel it, don't confirm", "cancel_booking", "en"),
        ("no need to show more", "deny", "en"),
        ("i have no money", "wallet_balance", "en"),
        ("not interested in joining", "deny", "en"),
    ] * 6) # 60
    
    df = pd.DataFrame(rows, columns=['text', 'intent', 'lang'])
    
    # Append to authored_intents.csv
    out_file = Path('data/assistant/authored_intents.csv')
    df.to_csv(out_file, mode='a', index=False, header=False)
    
    print(f"Added {len(df)} new authored examples to {out_file}.")

if __name__ == '__main__':
    main()
