# frozen_string_literal: true

require "squishling"

# squishling-claude_code registers its adapter with the pluggable-adapters API, so an older Squishling can't use it.
unless Squishling.respond_to?(:register_adapter)
  raise LoadError, "squishling-claude_code needs a Squishling release with pluggable adapters " \
                   "(Squishling.register_adapter); you have Squishling #{Squishling::VERSION}. Upgrade squishling."
end

require "claude_agent_sdk"
require_relative "claude_code/version"
require_relative "claude_code/conversation"
require_relative "claude_code/failure"
require_relative "claude_code/options"
require_relative "claude_code/adapter"

module Squishling
  # Runs Squishling through your local Claude Code CLI, on your Claude subscription. Requiring this gem registers the
  # adapter as :claude_code; see Squishling::ClaudeCode::Adapter.
  module ClaudeCode
    # Registers the adapter under :claude_code unless it is already there. Called when the gem loads; call it again
    # after Squishling.reset_adapters!, which forgets every adapter that isn't built in.
    def self.register
      Squishling.register_adapter(:claude_code, Adapter) unless Squishling.adapters.include?(:claude_code)
    end
  end
end

Squishling::ClaudeCode.register
