-- Update handle_new_user() function to remove email column reference
-- This fixes "Database error saving new user" during signup

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, user_id, display_name)
  VALUES (
    new.id,
    new.id,
    new.raw_user_meta_data->>'display_name'
  );
  RETURN new;
END;
$$;