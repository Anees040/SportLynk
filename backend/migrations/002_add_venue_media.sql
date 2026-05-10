-- 002_add_venue_media.sql
-- Add video_url to venues table

ALTER TABLE venues ADD COLUMN IF NOT EXISTS video_url TEXT;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS venue_photos TEXT[] DEFAULT '{}';
