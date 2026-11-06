-- Fix function search path security issue
-- Drop trigger first, then function, then recreate both
DROP TRIGGER IF EXISTS trigger_update_completed_at ON public.tasks;
DROP FUNCTION IF EXISTS public.update_completed_at();

-- Recreate function with secure search_path
CREATE OR REPLACE FUNCTION public.update_completed_at()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.completed = true AND OLD.completed = false THEN
    NEW.completed_at = NOW();
  ELSIF NEW.completed = false AND OLD.completed = true THEN
    NEW.completed_at = NULL;
  END IF;
  RETURN NEW;
END;
$$;

-- Recreate trigger
CREATE TRIGGER trigger_update_completed_at
  BEFORE UPDATE ON public.tasks
  FOR EACH ROW
  EXECUTE FUNCTION public.update_completed_at();