-- Clean slate RLS configuration for public.projects (fixed column name)

-- 1) Drop ALL existing policies on projects (including ALL/INSERT/SELECT/UPDATE/DELETE)
DO $$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'projects'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.projects;', p.policyname);
  END LOOP;
END $$;

-- Ensure RLS is enabled
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

-- 2) Recreate the correct policy set

-- INSERT: owner only
CREATE POLICY "projects_insert_owner"
ON public.projects
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- SELECT: owners or collaborators via has_project_access
CREATE POLICY "projects_select_access"
ON public.projects
FOR SELECT
TO authenticated
USING (has_project_access(auth.uid(), id));

-- UPDATE: owners or collaborators via has_project_access
CREATE POLICY "projects_update_access"
ON public.projects
FOR UPDATE
TO authenticated
USING (has_project_access(auth.uid(), id));

-- DELETE: only owner
CREATE POLICY "projects_delete_owner"
ON public.projects
FOR DELETE
TO authenticated
USING (auth.uid() = user_id);

-- 3) Keep trigger + default for user_id (re-assert to be safe)

-- Ensure user_id default comes from auth.uid()
ALTER TABLE public.projects
ALTER COLUMN user_id SET DEFAULT auth.uid();

-- (Re)create the set_project_owner trigger function
CREATE OR REPLACE FUNCTION public.set_project_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.user_id IS NULL THEN
    NEW.user_id := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

-- Recreate trigger to use the function
DROP TRIGGER IF EXISTS trg_set_project_owner ON public.projects;
CREATE TRIGGER trg_set_project_owner
BEFORE INSERT ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.set_project_owner();
