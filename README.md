# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

## Universal Linear routing (local extension)

Set `tracker.provider.project_slug: "*"` to poll across Linear projects. This
mode requires `tracker.required_labels` to include `symphony`; queries remain
limited to that opt-in label, including reconciliation and terminal cleanup.
Use the additional required label pattern `repo:*` to require exactly one safe
`repo:<name>` label. `tracker.excluded_labels` temporarily excludes scopes,
including dispatch, retry, and run reconciliation.

Local workspace hooks receive `SYMPHONY_ISSUE_ID`,
`SYMPHONY_ISSUE_IDENTIFIER`, and JSON `SYMPHONY_ISSUE_LABELS` through their
environment. A universal workflow must validate its allowed GitHub owner, clone
only the selected repository, and validate the repository origin before every
run, preserving existing work on a mismatch. Use a fresh workspace root when
migrating from dedicated workers, and prevent overlapping dispatch ownership.

## Linear issue conversations (local extension)

Set `tracker.comment_command_prefix` and `tracker.comment_wake_states` to enable
owner replies. A comment such as `@symphony: explain the failed check` resumes
the Codex thread already bound to that issue. Only comments authored by the
Linear identity behind the configured API key are accepted, and the prefix must
start the trimmed comment. Symphony delivers each comment ID once after a
successful turn. The durable binding retains the repository route, workspace,
worker host, and Codex home, so restarts preserve the same chat and MCP setup.
If the binding cannot be resumed or its execution context changes, the run
fails for operator review instead of silently replacing the conversation.
Commands become eligible after the issue's first thread binding is persisted.
