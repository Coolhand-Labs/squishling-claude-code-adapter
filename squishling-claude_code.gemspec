# frozen_string_literal: true

require_relative "lib/squishling/claude_code/version"

Gem::Specification.new do |spec|
  spec.name = "squishling-claude_code"
  spec.version = Squishling::ClaudeCode::VERSION
  spec.authors = ["Michael Carroll"]
  spec.email = ["mc@coolhandlabs.com"]

  spec.summary = "Squishling adapter that runs LLM calls through your local Claude Code (claude -p), so they count " \
                 "against your Claude subscription instead of API billing."
  spec.description = "A Squishling adapter that sends Ruby LLM calls through the Claude Code CLI installed on your " \
                     "machine, using the Claude Agent SDK for Ruby. The CLI authenticates with your own Claude " \
                     "subscription (Pro or Max), so development calls count against its usage limits instead of " \
                     "per-token API charges. Strict structured output, token usage, and model selection are " \
                     "mapped to Squishling's adapter contract. Meant for one developer on their own machine."
  spec.homepage = "https://github.com/Coolhand-Labs/squishling-claude-code-adapter"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/tree/main/docs"

  # Ship only what's tracked in git, minus development-only files.
  dev_files = %w[AGENTS.md CLAUDE.md]
  dev_prefixes = %w[bin/ test/ spec/ features/ examples/ assets/
                    .git .claude .idea .rubocop .simplecov .rspec Gemfile]
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      File.expand_path(f) == __FILE__ || dev_files.include?(f) || f.start_with?(*dev_prefixes)
    end
  end
  spec.require_paths = ["lib"]

  # The first Squishling with pluggable adapters (Squishling.register_adapter). Raise this to that release's number.
  spec.add_dependency "squishling", ">= 0.4.0"
  # Does the heavy lifting: finds and starts the claude CLI, speaks its protocol, and parses the result.
  spec.add_dependency "claude-agent-sdk", "~> 1.4"

  spec.metadata["rubygems_mfa_required"] = "true"
end
