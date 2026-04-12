---
name: feishu-task-ops
description: Use when working with Feishu task/tasklist automation via lark-cli, especially for tasklist creation, task CRUD, task comments, task custom fields, task sections/groups, and task-to-section routing for planner-builder-auditor workflows.
---

# Feishu Task Ops

Use this skill when the job is to operate Feishu Task objects through `lark-cli`.

This skill is for:
- creating and inspecting tasklists
- creating, reading, and patching tasks
- writing and reading task comments
- creating and reading task custom fields
- creating and reading task sections/groups
- assigning tasks to specific sections

## Model

For the workflow used here:
- task `description` is the human-owned body
- task `comments` are the human/planner discussion surface
- task custom fields hold canonical machine-owned artifacts such as `Task Key`, `Current Plan`, `Builder Workpad`, `Auditor Verdict`, `PR`, and `Task Kind`
- `Task Key` should be a visible human-facing identifier such as `claworld/t100018`, derived from the native Feishu `task_id`
- task custom text fields are plain-text surfaces; do not rely on Markdown headings rendering as headings
- task section/group is the board column
- the default unnamed section should be treated as `Backlog`
- `task.extra` should hold only internal March hook state and bookkeeping such as:
  - the current internal `Building` hook (`builder` vs `planner_review`)
  - the current building phase (`pickup`, `execute`, `rework`, `review`)
  - processed fingerprints
- never put the primary human-facing workflow truth into `task.extra`

Do not treat `description` as the place for `Current Plan` or `Builder Workpad` if task custom fields already exist.

## Identity And Scopes

Check current auth first:

```bash
lark-cli auth status
```

For task workflows, the important scopes are usually:
- `task:task:read`
- `task:task:write`
- `task:tasklist:read`
- `task:tasklist:write`
- `task:comment:read`
- `task:comment:write`
- `task:custom_field:read`
- `task:custom_field:write`
- `task:section:read`
- `task:section:write`

If scopes were just granted in the Feishu app backend, re-run device auth to refresh the local user token.

## Fast Path

1. Inspect the target tasklist and current auth.
2. Read task custom fields and task sections.
3. Ensure required fields and sections exist.
4. Ensure the canonical fields exist: `Task Key`, `Current Plan`, `Builder Workpad`, `Auditor Verdict`, `PR`, `Task Kind`.
5. Create or patch tasks.
6. Route tasks into the correct section with `add_tasklist`.

## Important API Notes

- `task.extra` is an opaque string, not a JSON object. If you use it, serialize JSON yourself.
- `tasks.patch` supports `custom_fields`, but does **not** support moving tasks between tasklist sections.
- `lark-cli task tasks create --data @file` may fail with `invalid JSON format`; prefer inline JSON or `jq -n` command substitution.
- In `tasks.create`, `tasklists` entries use `tasklist_guid`, not `guid`.
- To place a task into a section, use:
  - `POST /task/v2/tasks/{task_guid}/add_tasklist`
  - with `tasklist_guid` and `section_guid`
- Feishu tasklists keep an undeletable default unnamed section. Use that as `Backlog` instead of creating a separate `Backlog` section in normal setups.
- `task.tasks.get` returns single-select field values as the selected option guid, not the option name.
- When writing custom text fields, send real newlines. Do not write literal `\n` into stored field values.

## When To Read References

Read [references/commands.md](references/commands.md) when you need concrete `lark-cli` commands or raw API payloads for:
- auth refresh
- tasklist creation
- task create/get/patch
- comments
- custom fields
- sections/groups
- section assignment
