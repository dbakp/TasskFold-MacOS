// Importing this module refuses to continue unless the operator passed --remote.
// These scripts talk to a hosted Supabase branch/project; automated tests must never reach them by accident.
// Refusal is immediate and non-interactive (exit 2). See docs/TESTING_ISOLATION.md.
const key = Symbol.for("taskfold.remote-guard");
if (globalThis[key] === undefined) {
  const flagged = process.argv.includes("--remote");
  process.argv = process.argv.filter((argument) => argument !== "--remote");
  globalThis[key] = flagged;
}
if (!globalThis[key]) {
  console.error(`REFUSED: ${process.argv[1] ?? "this script"} talks to a hosted Supabase project. Re-run with --remote if that is intended. See docs/TESTING_ISOLATION.md.`);
  process.exit(2);
}
