-- Create labels table for color-coded tags
CREATE TABLE public.labels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  name TEXT NOT NULL,
  color TEXT NOT NULL DEFAULT '#3b82f6',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, name)
);

-- Enable RLS
ALTER TABLE public.labels ENABLE ROW LEVEL SECURITY;

-- RLS Policies for labels
CREATE POLICY "Users can view their own labels"
ON public.labels
FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own labels"
ON public.labels
FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own labels"
ON public.labels
FOR UPDATE
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own labels"
ON public.labels
FOR DELETE
USING (auth.uid() = user_id);

-- Create index for faster lookups
CREATE INDEX idx_labels_user_id ON public.labels(user_id);