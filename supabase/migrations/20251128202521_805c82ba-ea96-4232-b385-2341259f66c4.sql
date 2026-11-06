-- Create secure view that masks invited_email for non-owners
-- This fixes EXPOSED_SENSITIVE_DATA security finding
CREATE OR REPLACE VIEW public.project_collaborators_secure AS
SELECT 
  id,
  project_id,
  user_id,
  -- Only show email to project owners or the invited user themselves
  CASE 
    WHEN is_project_owner(auth.uid(), project_id) THEN invited_email
    WHEN user_id = auth.uid() THEN invited_email
    ELSE NULL
  END as invited_email,
  role,
  status,
  invited_by,
  created_at,
  accepted_at
FROM public.project_collaborators;

-- Grant SELECT on the view to authenticated users
GRANT SELECT ON public.project_collaborators_secure TO authenticated;