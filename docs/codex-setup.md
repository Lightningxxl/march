# Codex Setup

March ships canonical Codex skill definitions in `.codex/skills/`.

If your Codex setup already loads repo-local skills, you do not need an extra
install step.

If it does not, copy or symlink the bundled skills into your Codex home:

```bash
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_HOME_DIR/skills"
cp -R .codex/skills/* "$CODEX_HOME_DIR/skills/"
```

Bundled skills:

- `feishu-task-ops`
- `pull`
- `push`
- `land`
- `debug`
- `commit`

Optional helper:

- `.codex/worktree_init.sh`
  - initializes the March Elixir toolchain in a fresh local worktree
  - runs `mise trust` and `make setup` inside `elixir/`

What March expects from Codex:

- the Feishu task skill must be available for task/tasklist automation
- the git skills must be available for branch sync, push, and landing
- the debug skill should be available for stalled or failed runs

These skills are part of the public operator surface for March. Keep them in
sync with the repo's actual GitHub and CI behavior.
