-- Add email to profiles table
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS email text;

-- Update trigger to include email
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, user_id, display_name, email)
  VALUES (
    new.id,
    new.id,
    new.raw_user_meta_data->>'display_name',
    new.email
  );
  RETURN new;
END;
$$;

-- Backfill existing profiles with email from auth.users
UPDATE public.profiles p
SET email = u.email
FROM auth.users u
WHERE p.user_id = u.id AND p.email IS NULL;

-- Create enums for collaboration
CREATE TYPE public.collaborator_role AS ENUM ('owner', 'collaborator');
CREATE TYPE public.invitation_status AS ENUM ('pending', 'accepted', 'declined');

-- Create project_collaborators table
CREATE TABLE public.project_collaborators (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  invited_email text,
  role collaborator_role NOT NULL DEFAULT 'collaborator',
  status invitation_status NOT NULL DEFAULT 'pending',
  invited_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  accepted_at timestamp with time zone,
  
  UNIQUE (project_id, user_id),
  UNIQUE (project_id, invited_email),
  CONSTRAINT user_or_email CHECK (user_id IS NOT NULL OR invited_email IS NOT NULL)
);

ALTER TABLE public.project_collaborators ENABLE ROW LEVEL SECURITY;

-- Create security definer functions to avoid RLS recursion
CREATE OR REPLACE FUNCTION public.has_project_access(_user_id uuid, _project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.projects WHERE id = _project_id AND user_id = _user_id
    UNION
    SELECT 1 FROM public.project_collaborators 
    WHERE project_id = _project_id AND user_id = _user_id AND status = 'accepted'
  )
$$;

CREATE OR REPLACE FUNCTION public.is_project_owner(_user_id uuid, _project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.projects WHERE id = _project_id AND user_id = _user_id)
$$;

CREATE OR REPLACE FUNCTION public.get_user_id_by_email(_email text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM auth.users WHERE email = _email LIMIT 1
$$;

-- Update RLS policies for projects
DROP POLICY IF EXISTS "Users can view their own projects" ON public.projects;
DROP POLICY IF EXISTS "Users can update their own projects" ON public.projects;
DROP POLICY IF EXISTS "Users can delete their own projects" ON public.projects;

CREATE POLICY "Users can view accessible projects" ON public.projects
FOR SELECT USING (public.has_project_access(auth.uid(), id));

CREATE POLICY "Users with access can update projects" ON public.projects
FOR UPDATE USING (public.has_project_access(auth.uid(), id));

CREATE POLICY "Only owners can delete projects" ON public.projects
FOR DELETE USING (auth.uid() = user_id);

-- Update RLS policies for sections
DROP POLICY IF EXISTS "Users can view their own sections" ON public.sections;
DROP POLICY IF EXISTS "Users can create their own sections" ON public.sections;
DROP POLICY IF EXISTS "Users can update their own sections" ON public.sections;
DROP POLICY IF EXISTS "Users can delete their own sections" ON public.sections;

CREATE POLICY "Users can view accessible sections" ON public.sections
FOR SELECT USING (
  auth.uid() = user_id OR public.has_project_access(auth.uid(), project_id)
);

CREATE POLICY "Users can create sections in accessible projects" ON public.sections
FOR INSERT WITH CHECK (
  auth.uid() = user_id AND public.has_project_access(auth.uid(), project_id)
);

CREATE POLICY "Users can update accessible sections" ON public.sections
FOR UPDATE USING (
  auth.uid() = user_id OR public.has_project_access(auth.uid(), project_id)
);

CREATE POLICY "Users can delete accessible sections" ON public.sections
FOR DELETE USING (
  auth.uid() = user_id OR public.has_project_access(auth.uid(), project_id)
);

-- Update RLS policies for tasks
DROP POLICY IF EXISTS "Users can view their own tasks" ON public.tasks;
DROP POLICY IF EXISTS "Users can create their own tasks" ON public.tasks;
DROP POLICY IF EXISTS "Users can update their own tasks" ON public.tasks;
DROP POLICY IF EXISTS "Users can delete their own tasks" ON public.tasks;

CREATE POLICY "Users can view accessible tasks" ON public.tasks
FOR SELECT USING (
  auth.uid() = user_id OR 
  (project_id IS NOT NULL AND public.has_project_access(auth.uid(), project_id))
);

CREATE POLICY "Users can create accessible tasks" ON public.tasks
FOR INSERT WITH CHECK (
  auth.uid() = user_id AND
  (project_id IS NULL OR public.has_project_access(auth.uid(), project_id))
);

CREATE POLICY "Users can update accessible tasks" ON public.tasks
FOR UPDATE USING (
  auth.uid() = user_id OR 
  (project_id IS NOT NULL AND public.has_project_access(auth.uid(), project_id))
);

CREATE POLICY "Users can delete accessible tasks" ON public.tasks
FOR DELETE USING (
  auth.uid() = user_id OR 
  (project_id IS NOT NULL AND public.has_project_access(auth.uid(), project_id))
);

-- RLS policies for project_collaborators
CREATE POLICY "View collaborations" ON public.project_collaborators
FOR SELECT USING (
  public.has_project_access(auth.uid(), project_id) OR
  user_id = auth.uid() OR
  invited_email = (SELECT email FROM auth.users WHERE id = auth.uid())
);

CREATE POLICY "Owners can invite" ON public.project_collaborators
FOR INSERT WITH CHECK (public.is_project_owner(auth.uid(), project_id));

CREATE POLICY "Manage collaborations" ON public.project_collaborators
FOR UPDATE USING (
  public.is_project_owner(auth.uid(), project_id) OR
  (user_id = auth.uid() AND status = 'pending')
);

CREATE POLICY "Remove collaborations" ON public.project_collaborators
FOR DELETE USING (
  public.is_project_owner(auth.uid(), project_id) OR user_id = auth.uid()
);

-- Auto-link pending invites on signup
CREATE OR REPLACE FUNCTION public.link_pending_invites()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.project_collaborators
  SET user_id = NEW.id
  WHERE invited_email = NEW.email AND user_id IS NULL;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created_link_invites
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.link_pending_invites();

-- Update Storage RLS for task-attachments
CREATE POLICY "Users can access shared project attachments"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'task-attachments' AND
  EXISTS (
    SELECT 1 FROM public.tasks t
    WHERE t.id::text = (storage.foldername(name))[1]
    AND (t.user_id = auth.uid() OR public.has_project_access(auth.uid(), t.project_id))
  )
);