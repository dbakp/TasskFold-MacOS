-- Part A: Clean up INSERT policies on projects
-- Drop ALL insert policies on projects (safe reset)
DO $$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname='public' AND tablename='projects' AND cmd='INSERT'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.projects;', p.policyname);
  END LOOP;
END $$;

-- Make sure RLS is on
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

-- Create ONE permissive insert policy WITHOUT role restriction (like tasks)
CREATE POLICY "projects_insert_owner"
ON public.projects
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Part B: Add DEFAULT to user_id column
ALTER TABLE public.projects
ALTER COLUMN user_id SET DEFAULT auth.uid();