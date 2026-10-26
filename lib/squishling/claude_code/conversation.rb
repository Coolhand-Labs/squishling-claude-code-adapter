# frozen_string_literal: true

module Squishling
  module ClaudeCode
    # Turns Squishling's conversation into the single prompt `claude` takes. A first attempt is just the user's message;
    # a retry carries the rejected answer and the reason, which are replayed as an earlier part of the conversation.
    module Conversation
      module_function

      # messages: Squishling's [{ role: :user | :assistant, content: String }], ending with the message to answer.
      def prompt(messages)
        *history, latest = messages
        return latest[:content].to_s if history.empty?

        turns = history.map { |message| "[#{message[:role]}]\n#{message[:content]}" }.join("\n\n")
        "The conversation so far:\n\n#{turns}\n\nRespond to the latest message:\n\n#{latest[:content]}"
      end
    end
  end
end
