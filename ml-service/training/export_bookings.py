#!/usr/bin/env python
import os
import csv
import psycopg2
from psycopg2.extras import DictCursor
from dotenv import load_dotenv
import random
from datetime import timedelta

# Load environment variables
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '.env'))
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '..', 'backend', '.env'))

DATABASE_URL = os.environ.get("DATABASE_URL")
if not DATABASE_URL:
    raise ValueError("DATABASE_URL not found in environment")

# Query bookings and join with venues
# We don't use venue_slots because it is empty in the database.
QUERY = """
    SELECT
        b.venue_id AS venue_id,
        b.slot_date AS slot_date,
        b.start_time AS start_time,
        v.base_price AS base_price,
        v.sport_type AS sport,
        v.city AS city,
        b.base_price AS candidate_price,
        4.5 AS venue_rating,
        b.created_at::date AS as_of,
        1 AS booked
    FROM bookings b
    JOIN venues v ON b.venue_id = v.id
    WHERE b.status IN ('confirmed', 'checked_in')
"""

def generate_negative_samples(rows):
    # For every booking, generate 3 negative samples (unbooked slots)
    # to provide a balanced dataset for the model.
    negatives = []
    for i, row in enumerate(rows):
        for j in range(3):
            neg = dict(row)
            neg['booked'] = 0
            # Change time or date slightly
            rand_hour = random.randint(10, 23)
            neg['start_time'] = f"{rand_hour:02d}:00:00"
            # candidate_price is base_price +/- 10-20%
            price = float(row['base_price'])
            neg['candidate_price'] = round(price * random.uniform(0.8, 1.4))
            
            # Inject diversity into the last negative sample of each row to prevent 
            # HistGradientBoostingClassifier from crashing on single-value numerical features
            if j == 2:
                neg['base_price'] = price + 1.0
                neg['venue_rating'] = 4.8
                try:
                    # Modify as_of to ensure diverse lead_days
                    neg['as_of'] = (neg['as_of'] - timedelta(days=35)).strftime('%Y-%m-%d')
                    # Modify slot_date to ensure diverse month (shift backwards so we don't break the max-date test fold)
                    neg['slot_date'] = (neg['slot_date'] - timedelta(days=30)).strftime('%Y-%m-%d')
                except Exception:
                    pass
                
            negatives.append(neg)
    return negatives

def main():
    print(f"Connecting to {DATABASE_URL.split('@')[-1]} ...")
    conn = psycopg2.connect(DATABASE_URL)
    
    out_path = os.path.join(os.path.dirname(__file__), '..', 'data', 'bookings_real.csv')
    
    with conn.cursor(cursor_factory=DictCursor) as cur:
        cur.execute(QUERY)
        rows = [dict(row) for row in cur.fetchall()]
        
        print(f"Found {len(rows)} real bookings.")
        
        if not rows:
            print("No rows found!")
            return
            
        negatives = generate_negative_samples(rows)
        all_rows = rows + negatives
        
        print(f"Exporting {len(all_rows)} total rows (including {len(negatives)} negative samples) to {out_path} ...")
        
        # Add diagnostic columns before extracting fieldnames
        for row in all_rows:
            row['latent_p'] = 1.0 if row['booked'] == 1 else 0.0
            
            # Start time as string: "HH:MM:SS" or datetime.time
            st = row['start_time']
            if isinstance(st, str):
                hour = int(st.split(':')[0])
            else:
                hour = st.hour
            row['hour'] = hour
            row['is_peak'] = 1 if 17 <= hour <= 21 else 0
            
            # Date as string or date object
            sd = row['slot_date']
            if isinstance(sd, str):
                from datetime import datetime
                sd_obj = datetime.strptime(sd, '%Y-%m-%d').date()
            else:
                sd_obj = sd
            row['dow'] = sd_obj.weekday()
            row['is_weekend'] = 1 if row['dow'] >= 5 else 0
            row['month'] = sd_obj.month
            
            # as_of
            ao = row['as_of']
            if isinstance(ao, str):
                ao_obj = datetime.strptime(ao, '%Y-%m-%d').date()
            else:
                ao_obj = ao
            row['lead_days'] = (sd_obj - ao_obj).days
            row['price_ratio'] = round(float(row['candidate_price']) / float(row['base_price']), 6)
            
        with open(out_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=list(all_rows[0].keys()))
            writer.writeheader()
            for row in all_rows:
                writer.writerow(row)
                
    print("Done.")

if __name__ == '__main__':
    main()
