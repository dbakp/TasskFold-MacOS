-- A CHECK evaluating to SQL NULL succeeds. Require the document envelope explicitly,
-- including version and root, so a missing key is rejected rather than silently stored.
alter table public.saved_views drop constraint saved_views_query_ast_check;
alter table public.saved_views add constraint saved_views_query_ast_check check (
 coalesce(jsonb_typeof(query_ast)='object' and query_ast->'version'='1'::jsonb and jsonb_typeof(query_ast->'root')='object',false)
);
