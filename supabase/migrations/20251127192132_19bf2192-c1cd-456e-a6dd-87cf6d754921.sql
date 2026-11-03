-- Add order_index column to projects table
ALTER TABLE projects ADD COLUMN order_index INTEGER NOT NULL DEFAULT 0;

-- Set initial order based on created_at for existing projects
WITH ordered_projects AS (
  SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at) - 1 AS new_order
  FROM projects
)
UPDATE projects
SET order_index = ordered_projects.new_order
FROM ordered_projects
WHERE projects.id = ordered_projects.id;

-- Create index for better query performance
CREATE INDEX idx_projects_user_order ON projects(user_id, order_index);