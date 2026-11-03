-- Fix projects INSERT policy to allow NULL user_id at check time while still enforcing ownership via trigger

-- 1) Replace INSERT policy with COALESCE-based version
DROP POLICY IF EXISTS "projects_insert_owner" ON public.projects;
DROP POLICY IF EXISTS "projects_insert_owner" ON public.projects; -- just in case naming differs

CREATE POLICY "projects_insert_owner"
ON public.projects
FOR INSERT
TO authenticated
WITH CHECK (
  auth.uid() = COALESCE(user_id, auth.uid())
);

-- 2) Ensure trigger and NOT NULL are kept (already created in previous migration)
--    No structural changes here to avoid duplication; this migration focuses on the RLS policy behavior only.