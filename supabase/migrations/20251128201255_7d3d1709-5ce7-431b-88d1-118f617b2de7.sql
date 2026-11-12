-- Create function to get collaborators with conditional email visibility
-- Only project owners can see invited_email addresses
CREATE OR REPLACE FUNCTION public.get_project_collaborators_safe(_project_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  invited_email text,
  role collaborator_role,
  status invitation_status,
  created_at timestamptz,
  accepted_at timestamptz,
  display_name text,
  avatar_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 
    pc.id,
    pc.user_id,
    -- Only show email to project owners
    CASE 
      WHEN is_project_owner(auth.uid(), _project_id) THEN pc.invited_email
      ELSE NULL
    END as invited_email,
    pc.role,
    pc.status,
    pc.created_at,
    pc.accepted_at,
    p.display_name,
    p.avatar_url
  FROM public.project_collaborators pc
  LEFT JOIN public.profiles p ON p.user_id = pc.user_id
  WHERE pc.project_id = _project_id
    AND pc.status IN ('pending', 'accepted')
    -- Apply same access rules as RLS
    AND (
      is_project_owner(auth.uid(), _project_id)
      OR (pc.user_id = auth.uid())
      OR (has_project_access(auth.uid(), _project_id) AND pc.status = 'accepted')
    )
$$;