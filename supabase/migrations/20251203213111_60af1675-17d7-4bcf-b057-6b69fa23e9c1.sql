-- Delete all tasks for user davidbakposada@gmail.com
DELETE FROM tasks WHERE user_id = 'c3318b7a-75b8-40d1-a93a-476a750aff95';

-- Delete all sections for this user
DELETE FROM sections WHERE user_id = 'c3318b7a-75b8-40d1-a93a-476a750aff95';

-- Delete all project collaborators for projects owned by this user
DELETE FROM project_collaborators WHERE project_id IN (
  SELECT id FROM projects WHERE user_id = 'c3318b7a-75b8-40d1-a93a-476a750aff95'
);

-- Delete all projects for this user
DELETE FROM projects WHERE user_id = 'c3318b7a-75b8-40d1-a93a-476a750aff95';