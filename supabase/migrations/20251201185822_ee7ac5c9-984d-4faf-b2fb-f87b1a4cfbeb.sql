-- 1) Function to set user_id automatically
CREATE OR REPLACE FUNCTION public.set_project_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  IF NEW.user_id IS NULL THEN
    NEW.user_id := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

-- 2) Trigger to call it
DROP TRIGGER IF EXISTS trg_set_project_owner ON public.projects;
CREATE TRIGGER trg_set_project_owner
BEFORE INSERT ON public.projects
FOR EACH ROW EXECUTE FUNCTION public.set_project_owner();

-- 3) Ensure the INSERT policy is simple and strict
DROP POLICY IF EXISTS "Users can create their own projects" ON public.projects;

CREATE POLICY "Users can create their own projects"
ON public.projects
FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id);