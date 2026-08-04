# Memorium — Project Rules

## Commit at the end of every task

When you finish making code changes (at the end of the query/build, once the work is
complete and verified), **commit the changes**. Do not leave the working tree dirty for
the user to clean up.

Rules for the commit:

- Commit only when the change is actually finished and working. If something is broken or
  half-done, say so instead of committing.
- Stage the files you touched (`git add <paths>`), not `git add -A` — never sweep in
  unrelated local changes.
- Write a **descriptive** message that explains *what* changed and *why*, not just "fix"
  or "update". Format:

  ```
  <area>: <short summary of what changed>

  - <specific change 1>
  - <specific change 2>

  <why it was needed, if not obvious from the summary>
  ```

  Use `ios:`, `server:`, or `docs:` as the area prefix where it fits.
- One logical change per commit. If the task covered several unrelated things, split them
  into separate commits.
- Do **not** `git push` unless the user explicitly asks.
- If already on `master`, still commit there (this project works directly on `master`) —
  unless the user asked for a branch.
- Never commit secrets, `.env` files, credentials, or build artifacts. Check `git status`
  before staging.
- Tell the user what was committed after doing it.
