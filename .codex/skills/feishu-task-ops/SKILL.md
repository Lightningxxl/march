---
name: feishu-task-ops
description: Use when working with Feishu task/tasklist automation via lark-cli, especially for tasklist creation, task CRUD, task comments, task custom fields, task sections/groups, and task-to-section routing for planner-builder-auditor workflows.
---

# Feishu Task Ops

Use this skill when the job is to operate Feishu Task objects through `lark-cli`.

This skill is for:
- creating and inspecting tasklists
- creating, reading, and patching tasks
- deleting or cleaning tasks and tasklists after exact candidate selection
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
- `task:task:delete`
- `task:tasklist:read`
- `task:tasklist:write`
- `task:tasklist:delete`
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

## Destructive Ops

Treat delete/remove/archive requests as dangerous operations.

- use a read-then-mutate flow: inspect first, mutate second
- for board-scoped cleanup, prefer `lark-cli task tasklists tasks` over `lark-cli task tasks list`
- use `task.tasks.list` only for "my tasks" style requests; it is not the right primitive for precise cleanup inside a specific tasklist
- narrow delete candidates in this order whenever possible:
  - target `tasklist_guid`
  - target `section_guid` or default backlog section when the request is board-column scoped
  - `completed` state
  - exact summary/description/custom-field match
  - final explicit `task_guid` set
- do not bulk delete from a vague keyword alone such as "delete test tasks" without first enumerating exact matches
- if the user says `clean up`, `close`, or `clear` but does not explicitly require deletion, prefer non-destructive cleanup first:
  - patch `completed_at`
  - move tasks into a holding section such as `Done` or `Backlog`
- require user confirmation before delete when:
  - the candidate set spans multiple tasklists
  - the filter is not easily explainable in one sentence
  - non-completed tasks would be removed unexpectedly
  - more than 5 tasks would be deleted
- after destructive actions, report the exact deleted objects using `task_guid` plus summary

## Important API Notes

- `task.extra` is an opaque string, not a JSON object. If you use it, serialize JSON yourself.
- `tasks.patch` supports `custom_fields`, but does **not** support moving tasks between tasklist sections.
- `lark-cli task tasks create --data @file` may fail with `invalid JSON format`; prefer inline JSON or `jq -n` command substitution.
- local `lark-cli` supports `task tasks delete` and `task tasklists delete`, even though some official plugin tool surfaces only document create/get/list/patch flows.
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
- task create/get/patch/delete
- tasklist delete and member removal
- comments
- custom fields
- sections/groups
- section assignment
- destructive dry-run and exact-match cleanup patterns
