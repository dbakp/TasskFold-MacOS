-- Drop the existing INSERT policy
DROP POLICY IF EXISTS "Users can create their own projects" ON public.projects;

-- Create new INSERT policy with subquery pattern (Supabase recommended)
CREATE POLICY "Users can create their own projects" 
ON public.projects 
FOR INSERT 
WITH CHECK ((SELECT auth.uid()) = user_id);