-- Add onesignal_player_id column to profiles table
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS onesignal_player_id text;

-- Add notification_sent_at column to tasks to track sent notifications
ALTER TABLE public.tasks 
ADD COLUMN IF NOT EXISTS notification_sent_at timestamp with time zone;