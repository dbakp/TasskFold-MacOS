-- Create indexes on tasks table for optimal query performance
CREATE INDEX IF NOT EXISTS idx_tasks_user_id_created_at 
  ON tasks(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tasks_user_id_completed 
  ON tasks(user_id, completed);

CREATE INDEX IF NOT EXISTS idx_tasks_user_id_due_date 
  ON tasks(user_id, due_date);

CREATE INDEX IF NOT EXISTS idx_tasks_user_id_project_id 
  ON tasks(user_id, project_id);

-- Composite index for upcoming page (uncompleted tasks with due dates)
CREATE INDEX IF NOT EXISTS idx_tasks_user_upcoming 
  ON tasks(user_id, completed, due_date) 
  WHERE completed = false AND due_date IS NOT NULL;

-- Composite index for today page
CREATE INDEX IF NOT EXISTS idx_tasks_user_today 
  ON tasks(user_id, due_date, completed) 
  WHERE completed = false;