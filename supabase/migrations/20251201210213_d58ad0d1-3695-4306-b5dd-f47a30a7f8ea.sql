-- Drop the security definer view as it's no longer needed
-- All queries now use the base project_collaborators table directly
-- Email masking is handled by the get_project_collaborators_safe() RPC function where needed
DROP VIEW IF EXISTS public.project_collaborators_secure;