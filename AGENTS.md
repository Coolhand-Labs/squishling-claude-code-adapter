# Development Guidelines

Rules for any agent (or human) working in this repo. `CLAUDE.md` imports this file.

## What this gem is

`squishling-claude_code` is an adapter for [Squishling](https://github.com/Coolhand-Labs/squishling). It runs
Squishling's LLM calls through the **Claude Code CLI installed on the developer's machine** (`claude -p`), which
authenticates with the developer's own Claude subscription (Pro or Max). Development calls then count against the plan's
usage limits instead of per-token API charges.

It is a development tool for one person on their own machine, not a way to serve other people's requests. The heavy
lifting (finding and starting the CLI, its protocol, parsing the result) is delegated to the
[`claude-agent-sdk`](https://github.com/rubycatco/claude-agent-sdk-ruby) gem; this gem maps Squishling's adapter
contract onto it.

## Verify before you push

```bash
bundle exec rake    # RSpec (offline, ClaudeAgentSDK.ask is stubbed) + RuboCop — both must pass
```

CI also runs [exhale](https://github.com/tools4imps/exhale-ruby) (duplication and complexity gate, whole-codebase
sweep). Run it locally with `bin/exhale dry --include-tests` and `bin/exhale complexity`; don't
introduce new duplicate code or methods over the complexity floor.

After the feature or fix is built and `rake` is green, run `/loop-review` until it comes back clean (see
[Review and release skills](#review-and-release-skills)).

The live test is `examples/claude_code_example.rb`. It needs the `claude` CLI installed and logged in with a Pro or Max
plan, and spends a little of that plan's usage limits (typically about 12 small Haiku calls, up to about 20), so it can't run in CI; it runs
during `/prep-release`. If you touch the options, the credential handling, the error mapping, or the prompt, run it
yourself first. Never delete an assertion, mark a spec pending, or rescue-and-swallow to get green.

## Runtime dependencies

The gem's runtime dependencies are `squishling` and `claude-agent-sdk`. Keep it that way:

- **Delegate to `claude-agent-sdk`; don't reimplement it.** Use its public API only (`ClaudeAgentSDK.ask`,
  `ClaudeAgentOptions`, `EFFORT_LEVELS`, the error classes, the `ResultMessage` readers), not its internals
  (`CommandBuilder`, `Query`, transports). The one exception is `Options::Isolated`, which overrides the SDK's private
  `merge_with_defaults` because the SDK has no opt-out for `ClaudeAgentSDK.configure`'s global `default_options` (a host
  app's MCP servers, plugins, permission mode, or model would otherwise reach every call); a spec sets defaults and checks
  none arrive. The requirement is `~> 1.4`; raise it deliberately and re-run the specs and the live example.
- **No other gem**, and no HTTP client: nothing here talks to a network. The `claude` CLI does, not this gem.
- Don't call the SDK's CLI installer. The gem uses the `claude` the developer already has (or `cli_path:`); it never
  downloads or vendors an executable.
- Development-only gems go in the `Gemfile`'s `:development, :test` group, never the gemspec.
- The `Gemfile` points `squishling` at its `main` branch until a Squishling release has pluggable adapters; the gemspec
  requirement must be raised to that release before this gem's first release (the `/prep-release` skill checks it).
- No Ruby-version-conditional gems in the `Gemfile`: the committed `Gemfile.lock` is installed in frozen
  mode on every Ruby in the CI matrix (3.3–4.0), so it must resolve identically everywhere.
- `examples/`, `spec/`, `bin/`, and agent files are excluded from the packaged gem (see the gemspec).

## Design invariants

Flag any change that breaks one of these; they are behavior contracts, not style. The adapter contract itself is
Squishling's (`Squishling::Adapter::Base`, see its AGENTS.md); these are what this gem adds to it.

- **Only the public Squishling API.** Use `Squishling.register_adapter`, `Squishling::Adapter::Base`/`Request`/`Response`,
  and the error classes (plus `Squishling.reset_config!` in `spec/spec_helper.rb` only, which Squishling's docs
  recommend for test suites). Don't reach into Squishling internals from `lib/` or `spec/`: this gem is a plugin and has
  to survive Squishling's refactors.
- **Subscription billing is the point, and it must not silently turn into API billing.** By default
  (`subscription_only: true`) the `claude` process gets every `ANTHROPIC_*` and `CLAUDE_CODE_USE_*` variable (and
  `AWS_BEARER_TOKEN_BEDROCK`) removed from its environment, matched by prefix, because Claude Code prefers those over the
  login (keys, tokens, environment-selected federation and profile credentials, base URLs, provider switches). Never
  start Claude Code with `--bare` (it ignores the subscription login and needs an API key). The live example has a
  scenario that sets a bogus key and still expects success; keep it.
- **Credentials are never handled.** The gem doesn't read, store, log, set, or forward the subscription's OAuth token or
  any API key; the `claude` process authenticates itself. Don't add a login flow, a token option, or a way for one
  process to serve other people's requests: Anthropic's terms keep subscription credentials for the individual who
  bought the plan (see the README's note on use).
- **Claude Code is a plain completion, nothing more.** Every call starts it with no tools (`tools: []`), no settings
  sources (so no hooks, `CLAUDE.md`, or MCP servers), `strict_mcp_config`, no saved session, slash commands and skills
  disabled, memory files disabled (`CLAUDE_CODE_DISABLE_AUTO_MEMORY` and `CLAUDE_CODE_DISABLE_CLAUDE_MDS`, which the setting
  sources don't govern), the SDK's global defaults ignored, and an empty temporary working directory. A call sees only
  what Squishling sends. Don't loosen this.
- **Errors.** The adapter raises only `ConfigurationError` (setup mistakes: never retried or escalated) or `LLMError`
  (worth another attempt); any other exception propagates unwrapped. Setup mistakes: `claude` not installed, not logged
  in, a rejected key or credential, an unknown model, a rejected request, a param Claude Code can't take, a bad option.
  Rate and usage limits, an overlong request, a cut-off answer, a crash, a timeout, and an early stop are `LLMError`s.
- **Nothing Claude Code or the API said in an error or log.** `Failure` reads the result's text and status to decide the
  class and then uses only its own fixed texts; the SDK's exception messages (which can echo the request) are never
  repeated. Model output leaves only as the `Response` content.
- **Bounded and thread-safe.** Adapters run on worker threads for Squishling's samples. Each call is its own `claude`
  process; `max_concurrency` (a slot queue, always given back) caps how many run at once so concurrent samples don't use
  up the plan's limits together, and `timeout` stops a call. There is no shared mutable state beyond the slot queue.
- **Strict schemas in, JSON out.** The schema goes to Claude Code as `--json-schema` (minus `$schema`); the structured
  answer comes back as JSON text like every other adapter's. Squishling's own validation is the guarantee: this gem never
  trusts or validates the model's compliance for it.
- **Params.** Only `max_output_tokens` (as `CLAUDE_CODE_MAX_OUTPUT_TOKENS`) and `thinking` (`false`, or `{ effort: }`) are
  accepted; `temperature` and every other param raise `ConfigurationError`. `model:` is passed to `--model` (an alias like
  `haiku`/`sonnet`/`opus`, or a full name); `provider:` is ignored.
- **Requiring the gem on a Squishling without `register_adapter`** raises `LoadError` with the fix.

## Public API

`require "squishling/claude_code"` registers the adapter as `:claude_code`. The public surface is that adapter name and
its options (`timeout:`, `cli_path:`, `max_concurrency:`, `subscription_only:`), `Squishling::ClaudeCode::Adapter`,
`Squishling::ClaudeCode.register`, and `Squishling::ClaudeCode::VERSION`. `Options`, `Conversation`, and `Failure` are
internal. Don't break the public surface without a clear migration path in the changelog.

## Changelog and versioning

Do not add `CHANGELOG.md` entries or bump `lib/squishling/claude_code/version.rb` on feature/fix branches or in PRs. The
`/prep-release` skill is the sole owner of both — it writes changelog entries for the PRs actually shipping in
a release and bumps the version once, at release time.

Per-PR changelog edits create merge conflicts across concurrent branches for no benefit, since the entries get
rewritten from the final, user-approved set of merged PRs anyway. Leave `CHANGELOG.md` and `version.rb` alone
in your PR.

Releases publish to RubyGems via Trusted Publishing when a `vX.Y.Z` tag is pushed (`.github/workflows/publish.yml`).
Agents never create or push tags, run `rake release`, or `gem push`.

## Commits and PRs

Author commits and PRs as the local machine's GitHub user (whatever `git config user.name`/`user.email` and
`gh api user` report), never as Claude or any other agent. Don't add `Co-Authored-By: Claude` trailers or
"Generated with Claude Code" footers to commit messages or PR descriptions. A human owns every change, and a
single, accurate author makes it easy to track who is responsible for what.

## README and docs philosophy

The README is a landing page — what it is, install, quick start, requirements, the note on use, where to go next. Keep it
scannable. When in doubt, link rather than expand. Anything needing more than one code block, or deeper explanation (what
Claude Code is started with, billing and credentials, params, failure mapping, troubleshooting), goes in
`docs/how-it-works.md` or a new `docs/<topic>.md`, linked from the README.

Use full names ("Claude Code", "Claude subscription", "Ruby LLM structured output") in headings and the gemspec
description, so searches for "Ruby Claude Code", "use Claude subscription instead of API", or "Squishling adapter" find it.

## Review and release skills

- `/loop-review` (`.claude/skills/loop-review/SKILL.md`) — iterative review-and-fix of the current diff.
  **Always run it after building a feature or fix, before committing or pushing the branch** — don't wait to be
  asked. Report its result (clean or the remaining findings) along with the work.
- `/prep-release` (`.claude/skills/prep-release/SKILL.md`) — the release event: PR triage, merges,
  changelog/version, security red-team, the live example against a real Claude login, release-prep PR.
