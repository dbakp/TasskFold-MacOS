-- Create a security definer function to get user email by user_id
-- This allows us to fetch emails from auth.users without storing them in profiles
CREATE OR REPLACE FUNCTION public.get_user_email_by_id(_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT email FROM auth.users WHERE id = _user_id LIMIT 1
$$;

-- Remove the email column from profiles table
-- Email data should only be stored in auth.users
ALTER TABLE public.profiles DROP COLUMN IF EXISTS email;