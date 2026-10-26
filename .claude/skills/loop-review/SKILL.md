---
name: loop-review
description: |
  Iteratively runs code review against the current diff, applies fixes, and
  re-reviews until a round comes back clean (or a safety cap is hit). Use
  when the user types /loop-review, asks to "loop the review", "review
  until clean", "keep reviewing and fixing until nothing's left", or wants
  a self-healing code review cycle instead of a single one-shot pass.
user_invocable: true
version: 1.0.0
---

# Loop Review

This skill reviews the working diff, applies fixes, and re-reviews until a
round finds nothing new or a safety cap is reached. Use it after a merge,
a large diff, or whenever a single review pass isn't enough to converge on
a clean state.

Each round's review is done by spawning a fresh review Agent with the
inlined prompt below (see "The round loop") rather than invoking
`/code-review`: `/code-review` has `disable-model-invocation: true`, so it
can only be run directly by the user, never programmatically via the
`Skill` tool by an agent. Do not attempt to invoke it — spawn the Agent
instead.

## Scope

Default scope is the diff against the repo's base branch, working tree
included: `git diff origin/main` (substitute `origin/main` with whatever
base branch applies). Do NOT use the triple-dot form
(`git diff origin/main...HEAD`) as the default — it only sees committed
history and silently returns empty on a branch whose work is still
uncommitted, which would make round 1 rubber-stamp "LGTM" on real,
unreviewed changes, and would make every later round re-review the
pre-fix diff forever since this skill only edits the working tree (see
Safety) and never commits. If the arguments this skill was invoked with
name a path or a narrower scope, review only that instead of the full
diff.

Also run `git status --short` before round 1. Brand-new untracked files
(`??`) don't show up in `git diff origin/main` at all, which would let a
new file skip review entirely. If there are any, run
`git add -N <path>...` (intent-to-add — stages the path as an empty file
without staging its content, so it appears as a full addition in the diff
without changing what would actually be committed) before the first
review round. This is the one index mutation the loop makes; it's
intentional, left in place for the user to commit alongside everything
else (or undo with `git reset -- <path>` if not wanted) — see Safety.

This skill is deliberately diff-scoped. For a whole-package audit before a
release (full-codebase security red-team, docs review, everything since
the last tag) use `/prep-release` instead.

The invocation's arguments may also contain:
- An effort level describing how thorough each round's review Agent
  should be (`low`/`medium`/`high`/`max`). Default: `medium`. Pass this
  through as plain text in the review prompt (e.g. "Effort: EFFORT") —
  there's no tool-level effort parameter for a spawned Agent.
- A round cap override, e.g. `--max-rounds 3`. Default: 5.

## The round loop

Repeat the following cycle up to the round cap:

1. **Review.** Spawn a review Agent (via the `Agent` tool) against the
   current scope. Give it: the scope command from above, the round
   number, the effort level, the full "Review criteria" checklist below
   (including the severity taxonomy), and the list of fixes already
   applied in prior rounds (so it doesn't re-flag them). Ask it to return
   a numbered list of issues, each tagged with its severity bucket and
   prefixed in the form `1. [CRITICAL] file:line — problem — fix`, or the
   exact string `LGTM: No issues found.` if there are none. Its response
   should end with a line `TOKENS_USED: <number>` — its own best estimate
   of tokens consumed that round, approximate rather than metered, based
   on whatever visibility it has into its own context/conversation size.
   Because the response now ends with that line, the LGTM check is: the
   *first line* of the response is exactly `LGTM: No issues found.`, not
   the whole response. Also record `date +%s` immediately before spawning
   this round's review Agent — the start of this round's timing window
   for the CSV log (see Wrap-up).
2. **Clean round (first line `LGTM: No issues found.`) → run the Verify
   step (step 4) once** — a clean-looking diff can still have a broken
   test suite the reviewer Agent never ran. If Verify passes, converged:
   move to Wrap-up. If Verify fails, it's not actually converged: treat
   the failures as a `[CRITICAL]` finding and go to step 3, then run
   another round (subject to the round cap) to confirm the fix.
3. **Findings found → give every one of them a disposition.** For each
   finding, either fix it (using Edit, Write, and Bash tools to apply the
   fix directly in this session) or reject it with a one-line reason
   (false positive / out of scope / disagree with the call) — no silent
   skipping. Verify failures should essentially never be rejected; a
   reviewer-agent finding can be, when the reason genuinely holds up.
   Record, per round: what was found (with severity), what was fixed,
   and what was rejected (with its reason) — see the log format below —
   so the next round's reviewer prompt can list fixes as already-applied
   and the final report can show fixed/rejected counts.
4. **Verify.** Run `bundle exec rake` (`rspec` then `rubocop`, per the
   `Rakefile`) after applying this round's fixes. If it fails, that
   failure is itself a `[CRITICAL]` finding for the next round — don't
   move on with a red build. A fix can pass its own narrow spec while
   breaking something elsewhere, and the next round's reviewer Agent
   isn't checking test/lint output, only the diff. If a fix round changed
   something outside this repo's usual toolchain, discover the right
   command instead of assuming. Record `date +%s` again once Verify
   completes — the end of this round's timing window for the CSV log
   (see Wrap-up).
5. **Findings found and fixed** → do not declare victory yet. Run another
   round to confirm the fixes didn't introduce a regression and that
   nothing was missed.
6. **No-progress detection**: if two consecutive rounds return the same
   non-empty set of findings, fixing isn't resolving them mechanically
   (likely a design/architecture call that needs a human). Stop looping,
   list the stuck findings, and hand them to the user instead of retrying
   forever.
7. **Safety cap**: if the round cap is reached without converging or
   getting stuck, stop and report the remaining findings — don't loop
   silently past the cap.

Each round's fixes should stay reviewable: don't squash multiple rounds
into one silent edit. Note per-round changes in the final summary so the
user can inspect them with `git diff`.

Maintain a running log across rounds:

```
=== Round 1 ===
Reviewer found N issues (X critical, Y nice-to-have, Z nitpick):
  1. [CRITICAL] file:line — problem — fix
  2. [NICE-TO-HAVE] file:line — problem — fix
  ...
Fixed (F):
  - [what was done to resolve issue 1]
  - [what was done to resolve issue 2]
Rejected (R):
  - [issue N] — [one-line reason]
Tokens used (reviewer estimate): NNNN

=== Round 2 ===
...

=== RESULT ===
[CLEAN after N rounds] or [STOPPED at round cap — N issues remain] or
[STOPPED — no progress after N rounds, M issues remain]
```

## Review criteria

Give the review Agent spawned in each round the full checklist below —
correctness bugs, reuse/simplification/efficiency, and the repo-specific
items that follow. Nothing here is optional or a "beyond code-review"
extra; it's the whole review.

Every finding the review Agent returns must be tagged with one of these
severity buckets, prefixed onto the finding as shown in "The round loop"
step 1 (e.g. `1. [CRITICAL] file:line — problem — fix`):

- `[CRITICAL]` — security vulnerabilities, wrong/broken behavior,
  performance problems.
- `[NICE-TO-HAVE]` — DRY violations, missing test coverage, code-reuse
  opportunities.
- `[NITPICK]` — documentation, comments, naming, formatting-adjacent
  issues.

A failing `bundle exec rake` from the Verify step counts as `[CRITICAL]`
when tallying findings for the round log and CSV row.

The top-line priorities this repo cares about most: Ruby best practices
(DRY, semantic naming), gem publishing discipline (don't break the public
interface unless necessary; document and version appropriately when you
do), and security. This gem sits between an app and a developer's own Claude
login, so billing and credential handling get the same scrutiny as the
adapter logic. The bullets below are the concrete, repo-specific elaboration
of those priorities.

- **General AGENTS.md conformance**: read `AGENTS.md` (which `CLAUDE.md`
  imports) and flag any violation of it, not just the rules called out
  explicitly below — those are the ones worth spelling out because
  they're easy to miss, not the full list.
- **Public Squishling API only**: `lib/` and `spec/` may use
  `Squishling.register_adapter`/`adapters`/`reset_adapters!`/`configure`,
  `Squishling::Adapter::Base`/`Request`/`Response`, and Squishling's error
  classes — nothing else (plus `Squishling.reset_config!` in
  `spec/spec_helper.rb`, which Squishling's docs recommend for test suites).
  Flag any reach into Squishling internals. Check new behavior against the
  installed Squishling source (`bundle show squishling`), not memory.
- **Delegation to claude-agent-sdk**: the gem must use only the SDK's public
  API (`ClaudeAgentSDK.ask`, `ClaudeAgentOptions`, `EFFORT_LEVELS`, the error
  classes, the `ResultMessage` readers) — flag `CommandBuilder`, `Query`,
  transports, or anything reimplementing what the SDK already does (finding
  or starting `claude`, its protocol, parsing). Check new behavior against the
  installed SDK source (`bundle show claude-agent-sdk`), not memory, and note
  that `ask` is stubbed in the specs, so a change in how options reach the CLI
  is only caught by the live example.
- **Billing and credentials** (`lib/squishling/claude_code/adapter.rb`,
  `options.rb`): with `subscription_only: true` the `claude` process must get
  every `ANTHROPIC_*` and `CLAUDE_CODE_USE_*` variable (and
  `AWS_BEARER_TOKEN_BEDROCK`) removed, by prefix, and any other credential,
  endpoint, or provider variable in Claude Code's env-vars docs accounted for; Claude Code is never started with `--bare`; nothing reads,
  stores, logs, sets, or forwards a subscription token or API key (including
  `CLAUDE_CODE_OAUTH_TOKEN`); no login flow, token option, or multi-user mode.
  Flag anything that could make a subscription call bill the API, or leak a
  credential into an error, a log, a `Request`, or a result.
- **Isolation**: every call must keep Claude Code a plain completion — no tools,
  no setting sources, `strict_mcp_config`, no saved session, slash commands
  disabled, memory files disabled via env, the SDK's global `default_options`
  ignored (`Options::Isolated`), an empty temporary working directory that is
  always removed. Flag any loosening, and any path where project files, hooks,
  `CLAUDE.md`, MCP servers, plugins, or a host app's SDK configuration could
  reach a call.
- **Adapter contract & error taxonomy** (`adapter.rb`, `failure.rb`): the
  adapter raises only `ConfigurationError` (setup mistakes: never retried or
  escalated) or `LLMError` (worth another attempt); any other exception
  propagates unwrapped. Check that every SDK exception and every `ResultError`
  shape (status, `terminal_reason`, `subtype`, result text) maps to the right
  class, and that nothing Claude Code, the API, or the SDK said (including
  exception messages) is repeated in an error or log — only fixed texts.
- **Concurrency and process lifetime**: the slot queue is always given back
  (including on error and timeout), `max_concurrency` really bounds the number
  of `claude` processes, a timed-out call stops its process and removes its
  directory, and there is no unsynchronized shared state (samples call the
  adapter from worker threads).
- **Params and prompt**: only `max_output_tokens` and `thinking` are accepted,
  everything else raises; `model:` reaches `--model` as given; the schema goes
  out minus `$schema`; a retry's earlier turns are replayed faithfully in the
  prompt. Squishling's own validation stays the guarantee — nothing here trusts
  the model's compliance.
- **Backwards compatibility / gem publishing discipline**: the public surface is
  listed in `AGENTS.md` (the `:claude_code` adapter name and its options,
  `Squishling::ClaudeCode::Adapter`, `.register`, `VERSION`). Renamed or removed
  options, changed error classes, or changed defaults need a clear migration
  path. Every user-visible change needs a `CHANGELOG.md` entry, but per
  `AGENTS.md` those entries and version bumps are written by `/prep-release`
  at the release boundary, not per-PR — so don't flag a diff for lacking one;
  do flag a breaking change whose PR description doesn't explain the migration
  path. Check the runtime-dependency rule (only `squishling` and
  `claude-agent-sdk`) and that dev-only gems stay in the `Gemfile`'s
  development group.
- **Reuse / Ruby idiom / DRY**: semantic, expressive naming; idiomatic use of
  Ruby/Enumerable over manual loops where it reads better; no needless
  boilerplate.
- **Documentation**: per `AGENTS.md`'s "README and docs philosophy" — the
  README stays a landing page; anything needing more than one code block
  lives in `docs/how-it-works.md` or another `docs/<topic>.md`. Flag
  README/docs left stale or inconsistent with the code change (options table,
  params table, failure table, billing and credential notes, the note on use,
  troubleshooting), and anything that overstates what Anthropic's terms allow.
- **Testing**: new or changed behavior lacking corresponding RSpec coverage
  under `spec/`, and existing specs weakened (loosened matchers, removed
  assertions) to make them pass rather than fixing the underlying code. The SDK's
  `ask` is stubbed, so flag tests that only assert the stub returns what it was
  stubbed to return, and timing assumptions that could flake. Behavior only a
  real Claude Code can show (what flags reach the CLI, that a bogus API key is
  ignored, structured output, token usage, the timeout stopping the process)
  belongs in `examples/claude_code_example.rb`. Would `bundle exec
  rspec`/`bundle exec rubocop` catch this? If a lint or test gap is obvious,
  flag it — but don't treat a green run as proof the review is done; lint and
  tests don't check most of the bullets above (billing, credentials, isolation,
  process lifetime, docs).

## Wrap-up

Once the loop converges or stops early (per the rules above), report the
result in this shape:

1. **Overall result**: `CLEAN` (N rounds, Verify passing) or `STOPPED`
   (issues remain — either the round cap was reached, whether from
   unresolved findings or Verify still failing, or no-progress detection
   fired).
2. **Verification status**: pass/fail result of the last Verify step
   (`bundle exec rake`) that actually ran.
3. **Per-round breakdown**: findings found vs. fixed vs. rejected each
   round, broken down by severity (a small table is fine — round /
   critical / nice-to-have / nitpick / found / fixed / rejected).
4. **All files modified**: complete list of files touched across every
   round.
5. **Remaining issues** (only if stopped early): unresolved findings with
   context on why they need a human decision.
6. **CSV run log**: once the result above is otherwise final, append one
   row per round to `~/loop-review-outputs/squishling-claude_code.csv` (a
   Bash/file-write action — it does not commit anything, so it doesn't
   touch the never-commits policy in Safety). Create the directory and
   file with this header if either is absent:

   ```
   timestamp,branch,iteration,model,thinking_level,clock_seconds,tokens_used_approx,critical_found,nice_to_have_found,nitpick_found,total_found,issues_addressed,issues_ignored
   ```

   (The column is named `iteration` for consistency with the equivalent
   CSV in other Coolhand repos, even though this skill's own terminology
   is "round" everywhere else — populate it with the round number.) For
   each round, populate:
   - `timestamp` — `date -u +%Y-%m-%dT%H:%M:%SZ` at the moment the row is
     written.
   - `branch` — `git branch --show-current`.
   - `iteration` — the round number.
   - `model` — `default`.
   - `thinking_level` — the effort level used that round (default
     `medium`).
   - `clock_seconds` — the difference between the `date +%s` captured
     before spawning that round's review Agent (step 1) and the
     `date +%s` captured after that round's fix+Verify completed
     (step 4).
   - `tokens_used_approx` — the reviewer Agent's self-reported
     `TOKENS_USED` value for that round.
   - `critical_found` / `nice_to_have_found` / `nitpick_found` /
     `total_found` — that round's severity tally (a failed Verify counts
     as one `[CRITICAL]`).
   - `issues_addressed` — that round's fixed count.
   - `issues_ignored` — that round's rejected count.

   Use a plain `cat >> ~/loop-review-outputs/squishling-claude_code.csv <<EOF ...
   EOF` append per row — no CSV quoting needed. Note in the final report
   how many rows were appended and the file path.

## Rationalizations to resist

- *"The first round already looked clean, I don't need a confirming
  round."* A fix round can introduce its own regression. Always re-review
  after applying fixes before declaring convergence.
- *"Rubocop passed, so the review is done."* Lint passing is not the same
  as the review being clean — lint doesn't check the criteria above
  (interface breakage, changelog/version discipline, security). Run both.
- *"This finding keeps coming back, I'll just keep re-applying the same
  fix and it'll eventually take."* If the same non-empty finding set
  repeats across two rounds, mechanical fixing isn't going to resolve it.
  Stop and surface it — looping past that point just burns rounds for no
  gain.

## Safety

- Never force-push or amend existing commits as part of this loop.
- The skill only edits the working tree (plus the one `git add -N` index
  mutation noted in Scope, for untracked files); committing and pushing
  stays with the user.
