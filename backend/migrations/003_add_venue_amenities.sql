-- 003_add_venue_amenities.sql

-- Add amenities to venues
ALTER TABLE venues ADD COLUMN IF NOT EXISTS amenities JSONB DEFAULT '{}';

-- Add temporarily_locked to slot_status enum
ALTER TYPE slot_status ADD VALUE IF NOT EXISTS 'temporarily_locked';
