# Security Policy

## Supported Versions

Only the latest published version of `squishling-claude_code` on RubyGems is supported with security fixes.
Please upgrade to the latest version before reporting an issue.

## Reporting a Vulnerability

Please do **not** open a public GitHub issue for security vulnerabilities.

Instead, report vulnerabilities privately using one of the following:

- [GitHub Security Advisories](https://github.com/Coolhand-Labs/squishling-claude-code-adapter/security/advisories/new)
  for this repository (preferred)
- Email team@coolhandlabs.com

Please include a description of the vulnerability, steps to reproduce, and the impact you believe
it has. We aim to acknowledge reports within 3 business days and to provide a fix or mitigation
plan within 30 days, depending on severity.

## What this gem runs

The gem starts the `claude` executable (Claude Code) that is already on your machine, or the one at `cli_path:`, once per
request, as your user, with your environment minus the credentials that would bill the API. It never downloads or ships an
executable. It does not read, store, log, or forward your Claude login or any API key; `claude` authenticates itself. The
`claude-agent-sdk` gem it depends on does the process handling. Reports about the credential handling, the options Claude
Code is started with, or the request and result handling are in scope.
