-- Fix security issue: Remove invited_email check from SELECT policy
-- This prevents email harvesting while maintaining functionality since:
-- 1. The link_pending_invites() trigger automatically sets user_id when users sign up
-- 2. The invitation code already sets user_id if the user exists
-- 3. All app queries filter by user_id, not invited_email

DROP POLICY IF EXISTS "View collaborations" ON public.project_collaborators;

CREATE POLICY "View collaborations" 
ON public.project_collaborators 
FOR SELECT 
USING (
  has_project_access(auth.uid(), project_id) 
  OR (user_id = auth.uid())
);