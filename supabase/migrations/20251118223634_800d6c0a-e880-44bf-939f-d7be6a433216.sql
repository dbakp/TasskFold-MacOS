-- Add recurrence fields to tasks table
ALTER TABLE tasks
ADD COLUMN recurrence_pattern jsonb DEFAULT NULL,
ADD COLUMN is_recurring boolean DEFAULT false NOT NULL,
ADD COLUMN recurrence_parent_id uuid REFERENCES tasks(id) ON DELETE CASCADE DEFAULT NULL,
ADD COLUMN recurrence_end_date date DEFAULT NULL;

-- Create index for finding recurring tasks
CREATE INDEX idx_tasks_is_recurring ON tasks(is_recurring) WHERE is_recurring = true;

-- Create index for finding child recurring tasks
CREATE INDEX idx_tasks_recurrence_parent ON tasks(recurrence_parent_id) WHERE recurrence_parent_id IS NOT NULL;

COMMENT ON COLUMN tasks.recurrence_pattern IS 'JSON object storing recurrence configuration: {type: "daily"|"weekly"|"monthly"|"custom", interval: number, daysOfWeek: number[], dayOfMonth: number, endDate: string, count: number}';
COMMENT ON COLUMN tasks.is_recurring IS 'Flag indicating if this is a recurring task template';
COMMENT ON COLUMN tasks.recurrence_parent_id IS 'Reference to the parent recurring task if this is a generated instance';
COMMENT ON COLUMN tasks.recurrence_end_date IS 'Optional date when recurrence should stop generating new instances';