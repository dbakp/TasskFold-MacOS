import { prepare } from "../../supabase/functions/import-todoist/todoist.ts";
const source = {
  account: "synthetic-todoist-source",
  projects: [{ id: "p", name: "Reference project", color: "violet" }],
  sections: [{ id: "s", name: "Research", project_id: "p" }],
  labels: [{ id: "l", name: "reference", color: "violet" }],
  tasks: [{
    id: "root",
    content: "* Reference instructions",
    description: "Full instructions",
    project_id: "p",
    section_id: "s",
    labels: ["reference"],
    due: { date: "2026-11-01" },
  }, {
    id: "child",
    content: "* Child context",
    parent_id: "root",
    project_id: "p",
  }, {
    id: "action",
    content: "Do the work",
    parent_id: "child",
    project_id: "p",
  }],
  comments: new Map([["root", [{
    id: "comment",
    content: "Supporting notes",
    file_attachment: {
      file_url: "https://example.invalid/reference.pdf",
      file_name: "reference.pdf",
    },
  }]]]),
};
const result = await prepare(source, "f3010000-0000-4000-8000-000000000001");
await Deno.writeTextFile(Deno.args[0], JSON.stringify(result));
