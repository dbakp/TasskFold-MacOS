-- Fix email harvesting vulnerability: Restrict pending invitation visibility
-- Only project owners and the invited user themselves can see pending invitations with emails
-- Regular collaborators can only see accepted collaborations

DROP POLICY IF EXISTS "View collaborations" ON public.project_collaborators;

CREATE POLICY "View collaborations" 
ON public.project_collaborators 
FOR SELECT 
USING (
  -- Project owners can see all collaborations (including pending with emails)
  is_project_owner(auth.uid(), project_id)
  -- Users can see their own collaborations (including pending)
  OR (user_id = auth.uid())
  -- Regular collaborators can only see accepted collaborations (not pending ones)
  OR (has_project_access(auth.uid(), project_id) AND status = 'accepted')
);