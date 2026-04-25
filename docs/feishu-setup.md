# Feishu Setup

March is Feishu-native. The current runtime expects a Feishu tasklist with stable stages and a few custom fields.

## Bootstrap It Instead Of Hand-Creating It

Use the bootstrap script first:

```bash
./scripts/feishu-bootstrap --check-only
./scripts/feishu-bootstrap --create-tasklist "March Demo"
```

Or bootstrap an existing tasklist:

```bash
./scripts/feishu-bootstrap --tasklist-guid YOUR_TASKLIST_GUID
```

The script validates:

- `lark-cli` is installed and new enough
- local auth is valid
- required task scopes are granted

Then it ensures the expected sections and custom fields exist.

## Required Concepts

- one tasklist that March polls
- sections/groups that represent workflow stages
- comments enabled on tasks
- custom text fields for March-managed artifacts

## Typical Stages

The exact names are configurable, but a common setup is:

- Backlog, represented by Feishu's default unnamed section
- Planning
- Building
- Auditing
- Human Review
- Merging
- Done
- Canceled

## Runtime Stage Semantics

- `Planning`, `Building`, and `Auditing` are the automation stages whose comments March polls automatically.
- `Human Review` is a manual gate. Comments left there are visible to humans, but they do not wake planner or auditor automatically.
- `Merging` is a builder-owned landing stage. March still refreshes task state there, but it does not poll comments for that stage.
- `Done`, `Canceled`, and any other configured terminal stages are treated as finished work. When March sees a task enter a terminal stage, it marks the task completed.

## Common Custom Fields

- `Current Plan`
- `Builder Workpad`
- `Auditor Verdict`
- `PR`
- `Task Kind`
- `Task Key`

## Notes

- March currently uses Feishu Tasks as the primary collaboration backend.
- The internal runtime keeps an adapter boundary, but the product is intentionally Feishu-first today.
- A target repo still owns its own `MARCH.yml`, prompts, and repo docs.
- Human discussion should happen in task comments, not in extra hidden metadata.
- March discovers candidate work from tasklist entries that are still `completed=false`.
- Because discovery is based on `completed=false`, terminal stages should represent genuinely finished work; March will auto-complete those tasks so they fall out of later scans.
- `Task Kind` is expected to be a single-select field with: `feature`, `bug`, `improvement`, `refactor`, `docs`, `chore`.
