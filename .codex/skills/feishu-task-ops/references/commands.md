# Feishu Task Commands

## Auth

Check current token and scopes:

```bash
lark-cli auth status
```

Start a device-flow refresh for task scopes:

```bash
lark-cli auth login --no-wait --json --scope 'task:section:read task:section:write task:custom_field:read task:custom_field:write task:comment:read task:comment:write task:task:read task:task:write task:tasklist:read task:tasklist:write'
```

Complete a pending device flow:

```bash
lark-cli auth login --device-code '<device-code>'
```

If the job includes delete operations, confirm delete scopes too:

- `task:task:delete`
- `task:tasklist:delete`

## Tasklists

Create a tasklist:

```bash
lark-cli task tasklists create --as user --data '{"name":"symphony-task-mock"}'
```

Get tasklist details:

```bash
lark-cli task tasklists get --as user --params '{"tasklist_guid":"<tasklist-guid>"}'
```

List tasks in a tasklist:

```bash
lark-cli task tasklists tasks --as user --params '{"tasklist_guid":"<tasklist-guid>"}'
```

Delete a tasklist:

```bash
lark-cli task tasklists delete --as user --params '{"tasklist_guid":"<tasklist-guid>"}'
```

Remove members from a tasklist:

```bash
lark-cli task tasklists remove_members --as user --params '{"tasklist_guid":"<tasklist-guid>","user_id_type":"open_id"}' --data '{
  "members":[
    {"id":"<member-open-id>","type":"user"}
  ]
}'
```

## Tasks

Create a task directly inside a tasklist:

```bash
lark-cli task tasks create --as user --data '{
  "summary":"Plan: improve world entry preview without crossing relay or plugin boundaries",
  "description":"Improve world entry preview without crossing relay or plugin boundaries. Reuse existing preview surfaces when possible and explain boundary decisions clearly.",
  "extra":"{\"schema_version\":1}",
  "tasklists":[{"tasklist_guid":"<tasklist-guid>"}]
}'
```

If the payload is multiline, prefer `jq -n` rather than `--data @file`:

```bash
lark-cli task tasks create --as user --data "$(
  jq -n \
    --arg summary 'Plan: improve world entry preview without crossing relay or plugin boundaries' \
    --arg description 'Improve world entry preview without crossing relay or plugin boundaries. Reuse existing preview surfaces when possible and explain boundary decisions clearly.' \
    --arg tasklist_guid '<tasklist-guid>' \
    '{
      summary: $summary,
      description: $description,
      extra: "{\"schema_version\":1}",
      tasklists: [{tasklist_guid: $tasklist_guid}]
    }'
)"
```

Get a task:

```bash
lark-cli task tasks get --as user --params '{"task_guid":"<task-guid>"}'
```

Delete a task:

```bash
lark-cli task tasks delete --as user --params '{"task_guid":"<task-guid>"}'
```

Patch a task description or extra:

```bash
lark-cli task tasks patch --as user --params '{"task_guid":"<task-guid>"}' --data '{
  "update_fields":["description","extra"],
  "task":{
    "description":"Improve world entry preview without crossing relay or plugin boundaries. Reuse existing preview surfaces when possible and explain boundary decisions clearly.",
    "extra":"{\"schema_version\":1,\"meta\":{\"planner_planning_fingerprint\":\"<fingerprint>\"},\"workflow\":{\"active_role\":\"builder\",\"building_phase\":\"pickup\"}}"
  }
}'
```

Patch task custom fields:

```bash
lark-cli task tasks patch --as user --params '{"task_guid":"<task-guid>"}' --data '{
  "update_fields":["custom_fields"],
  "task":{
    "custom_fields":[
      {"guid":"<task-key-field-guid>","text_value":"claworld/t100018"},
      {"guid":"<current-plan-field-guid>","text_value":"Current Plan\n- Keep the change in product shell preview surfaces.\n- Do not modify relay core semantics.\n\nWhy This Plan\n- The request is presentation-oriented, not authority-oriented."},
      {"guid":"<builder-workpad-field-guid>","text_value":"host:path@sha\n\nPlan\n- [ ] Update docs/index.md\n\nAcceptance Criteria\n- [ ] Docs describe the preview ownership boundary clearly."},
      {"guid":"<auditor-verdict-field-guid>","text_value":"Scope\n- docs/index.md only\n\nVerdict\n- ready for human review"},
      {"guid":"<pr-field-guid>","text_value":"https://github.com/Lightningxxl/claworld/pull/150"},
      {"guid":"<task-kind-field-guid>","single_select_value":"<option-guid-for-feature-bug-or-improvement>"}
    ]
  }
}'
```

Notes:
- custom text fields are plain text surfaces; use plain section labels like `Current Plan` or `Why This Plan`
- do not rely on Markdown headings like `###`
- write real newlines instead of literal `\\n`
- for exact cleanup inside a board, prefer `task tasklists tasks` over `task tasks list`; `task tasks list` is a "my tasks" view, not a full tasklist view

## Destructive Read-Then-Delete Patterns

Inspect the delete schema before calling it:

```bash
lark-cli schema task.tasks.delete
```

Dry-run exact completed `test` task candidates inside one tasklist:

```bash
lark-cli task tasklists tasks --as user --params '{"tasklist_guid":"<tasklist-guid>","completed":true}' \
| jq '.data.items // [] | map(select((((.summary // "") + "\n" + (.description // "")) | ascii_downcase | test("(test|tests|testing|qa|fixture)")))) | map({task_guid:.guid, task_id, summary, completed_at})'
```

Dry-run exact `test` task candidates regardless of completion state:

```bash
lark-cli task tasklists tasks --as user --params '{"tasklist_guid":"<tasklist-guid>"}' \
| jq '.data.items // [] | map(select((((.summary // "") + "\n" + (.description // "")) | ascii_downcase | test("(test|tests|testing|qa|fixture)")))) | map({task_guid:.guid, task_id, summary, completed_at})'
```

Batch delete only after reviewing the exact candidate list:

```bash
CANDIDATES="$(
  lark-cli task tasklists tasks --as user --params '{"tasklist_guid":"<tasklist-guid>","completed":true}' \
  | jq -r '.data.items // [] | map(select((((.summary // "") + "\n" + (.description // "")) | ascii_downcase | test("(test|tests|testing|qa|fixture)")))) | .[].guid'
)"

printf '%s\n' "$CANDIDATES"

while IFS= read -r task_guid; do
  [ -n "$task_guid" ] || continue
  lark-cli task tasks delete --as user --params "$(jq -nc --arg task_guid "$task_guid" '{task_guid:$task_guid}')"
done <<< "$CANDIDATES"
```

Prefer soft cleanup instead of delete when the user says `clear`, `close`, or `done`:

```bash
lark-cli task tasks patch --as user --params '{"task_guid":"<task-guid>"}' --data '{
  "update_fields":["completed_at"],
  "task":{"completed_at":"2026-04-16T14:30:00+08:00"}
}'
```

## Comments

Add a task comment:

```bash
lark-cli task +comment --as user --task-id '<task-guid>' --content 'Human: comments should drive planner replanning.'
```

Notes:
- we used `+comment` for writes
- read-side comment integration uses the raw comments API

List task comments:

```bash
lark-cli api GET /task/v2/comments --as user --params '{
  "resource_type":"task",
  "resource_id":"<task-guid>"
}'
```

## Custom Fields

List custom fields for a tasklist:

```bash
lark-cli api GET /task/v2/custom_fields --as user --params '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>"
}'
```

Create a text custom field:

```bash
lark-cli api POST /task/v2/custom_fields --as user --data '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>",
  "name":"Current Plan",
  "type":"text"
}'
```

Create the visible human-facing task key field:

```bash
lark-cli api POST /task/v2/custom_fields --as user --data '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>",
  "name":"Task Key",
  "type":"text"
}'
```

Create a text `PR` field:

```bash
lark-cli api POST /task/v2/custom_fields --as user --data '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>",
  "name":"PR",
  "type":"text"
}'
```

Create a single-select custom field:

```bash
lark-cli api POST /task/v2/custom_fields --as user --data '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>",
  "name":"Task Kind",
  "type":"single_select",
  "single_select_setting":{
    "options":[
      {"name":"feature"},
      {"name":"bug"},
      {"name":"improvement"}
    ]
  }
}'
```

Patch a custom field definition:

```bash
lark-cli api PATCH /task/v2/custom_fields/<field-guid> --as user --data '{
  "update_fields":["name"],
  "custom_field":{"name":"Task Kind"}
}'
```

Notes:
- `single_select_setting.options[*].guid` are the option ids you later write into task values
- duplicate field cleanup may require patching names if delete is unavailable or undocumented
- keep `Task Key` in sync with the native Feishu `task_id`, using a repo prefix such as `claworld/`

Backfill or repair a `Task Key` value:

```bash
lark-cli task tasks patch --as user --params '{"task_guid":"<task-guid>"}' --data '{
  "update_fields":["custom_fields"],
  "task":{
    "custom_fields":[
      {"guid":"<task-key-field-guid>","text_value":"claworld/t100018"}
    ]
  }
}'
```

## Sections / Groups

List sections for a tasklist:

```bash
lark-cli api GET /task/v2/sections --as user --params '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>"
}'
```

Create a section:

```bash
lark-cli api POST /task/v2/sections --as user --data '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>",
  "name":"Planning"
}'
```

Rename an existing section:

```bash
lark-cli api PATCH /task/v2/sections/<section-guid> --as user --data '{
  "update_fields":["name"],
  "section":{"name":"Building"}
}'
```

Delete an unused section:

```bash
lark-cli api DELETE /task/v2/sections/<section-guid> --as user
```

Useful stage set:

```text
Planning
Building
Auditing
Human Review
Merging
Done
```

Notes:
- treat the default unnamed section as `Backlog`
- in normal setups, do not create a separate `Backlog` section

## Move A Task Into A Section

This is the key operation for board routing.

Do **not** use `tasks.patch` to move sections. It does not support `tasklists` updates.

Use:

```bash
lark-cli api POST /task/v2/tasks/<task-guid>/add_tasklist --as user --data '{
  "tasklist_guid":"<tasklist-guid>",
  "section_guid":"<section-guid>"
}'
```

This updates the task's `tasklists[].section_guid`.

Move a task into the default backlog section:

```bash
lark-cli api GET /task/v2/sections --as user --params '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>"
}'
```

Use the returned section whose `is_default` is `true`:

```bash
lark-cli api POST /task/v2/tasks/<task-guid>/add_tasklist --as user --data '{
  "tasklist_guid":"<tasklist-guid>",
  "section_guid":"<default-section-guid>"
}'
```

## Useful Read Patterns

Get task fields you care about:

```bash
lark-cli task tasks get --as user --params '{"task_guid":"<task-guid>"}' | jq '.data.task | {task_id, summary, description, custom_fields, tasklists}'
```

Map single-select option guid back to a name:

```bash
lark-cli api GET /task/v2/custom_fields --as user --params '{
  "resource_type":"tasklist",
  "resource_id":"<tasklist-guid>"
}' | jq '.data.items[] | select(.name=="Task Kind") | .single_select_setting.options'
```

## Working Conventions

Recommended field ownership:
- `Task Description`: human-owned body
- `Task Key`: visible, stable human-facing identifier derived from native `task_id`
- `Current Plan`: planner-owned canonical plan
- `Builder Workpad`: builder-owned canonical workpad
- `Auditor Verdict`: auditor-owned canonical verdict
- `PR`: builder-owned canonical pull request URL
- `Task Kind`: human/system classification

Recommended discussion surface:
- task comments for human <-> planner discussion

Recommended board routing:
- sections represent workflow stage
- the default unnamed section is backlog
- tasks are moved between sections with `add_tasklist`
- destructive cleanup should enumerate exact candidates first, then delete by explicit `task_guid`

Recommended coarse stage model:
- `Backlog`
- `Planning`
- `Building`
- `Auditing`
- `Human Review`
- `Merging`
- `Done`

Recommended internal hook model in `task.extra.workflow` while the task is in `Building`:
- `active_role = "builder"` with `building_phase = "pickup" | "execute" | "rework"`
- `active_role = "planner_review"` with `building_phase = "review"`
- leave human-visible truth in task custom fields and comments
