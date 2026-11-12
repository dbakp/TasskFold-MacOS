-- Add security definer function to get current user email safely
CREATE OR REPLACE FUNCTION public.get_current_user_email()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT email FROM auth.users WHERE id = auth.uid()
$$;

-- Drop and recreate the View collaborations policy to use the security definer function
DROP POLICY IF EXISTS "View collaborations" ON public.project_collaborators;

CREATE POLICY "View collaborations" ON public.project_collaborators
FOR SELECT USING (
  public.has_project_access(auth.uid(), project_id) OR
  user_id = auth.uid() OR
  invited_email = public.get_current_user_email()
);

-- Add foreign key from user_id to profiles for joining collaborator info
ALTER TABLE public.project_collaborators
ADD CONSTRAINT project_collaborators_user_id_profile_fkey
FOREIGN KEY (user_id) REFERENCES public.profiles(user_id) ON DELETE CASCADE;

-- Add foreign key from invited_by to profiles for joining inviter info
ALTER TABLE public.project_collaborators
ADD CONSTRAINT project_collaborators_invited_by_profile_fkey
FOREIGN KEY (invited_by) REFERENCES public.profiles(user_id) ON DELETE CASCADE;