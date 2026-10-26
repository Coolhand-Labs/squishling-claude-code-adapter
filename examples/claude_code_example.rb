# frozen_string_literal: true

# Live tests: Squishling scenarios through the :claude_code adapter, which runs your local Claude Code CLI (`claude -p`)
# on your own Claude subscription. Needs the `claude` CLI installed and logged in (`claude auth login`) with a Pro or
# Max plan. These scenarios spend a little of that plan's usage limits (typically about 12 small Haiku calls, up to
# about 20), not API credit.
#
# They check what the adapter does (typed results, nullable fields, multi-turn retries, token usage, concurrency, the
# credential stripping, error mapping), not how well a model answers, so they assert on shapes and types.
# Run: bundle exec ruby examples/claude_code_example.rb
# Exits 0 when every scenario passes, 1 otherwise (including when Claude Code isn't installed or logged in).

require "bundler/setup"
require "squishling/claude_code"

MODEL = ENV.fetch("CLAUDE_CODE_EXAMPLE_MODEL", "haiku")

def configure(adapter = :claude_code)
  Squishling.configure do |config|
    config.adapter = adapter
    config.default_escalation = [{ model: MODEL, attempts: 2 }]
  end
end
configure

Scenario = Struct.new(:name, :block)

def check(condition, message)
  raise message unless condition
end

# The squished classes the scenarios call.
module Fixtures
  class Reviewer
    include Squishling

    purpose "Classify the sentiment of the product review and rate it from 1 to 5."
    output_schema do
      string :sentiment, enum: %w[positive negative neutral]
      integer :score, minimum: 1, maximum: 5
      optional(:quote) { string }
    end
  end

  class InvoiceReader
    include Squishling

    purpose "Extract the invoice number, the line items, and the total."
    output_schema do
      string :invoice_number
      array :line_items do
        object do
          string :description
          integer :quantity
          number :unit_price
        end
      end
      number :total
    end
  end

  # squish_validate rejects the first answer, so the call asks again with the rejected output in the conversation.
  class CheckedColor
    include Squishling

    purpose "Reply with one lowercase word that names a color."
    output_schema { string :word }
    squish_validate do |result, **|
      @checks = (@checks || 0) + 1
      "pick a different color than #{result.word.inspect}" if @checks == 1
    end
    attr_reader :checks
  end

  class Fallback
    include Squishling

    purpose "Reply with one word."
    output_schema { string :word }
    squish_fallback { |_error, **| { word: "fallback" } }
  end
end

REVIEW = "Absolutely love it. Best purchase I've made all year."
INVOICE = "Invoice #INV-2041\n3 x Widget @ $10.00\n2 x Gadget @ $25.00\nTOTAL DUE: $80.00"

SCENARIOS = [
  Scenario.new("an enum and a numeric range come back as a typed result", lambda {
    result = Fixtures::Reviewer.call(review: REVIEW)
    check(result.squished?, "expected an LLM result")
    check(%w[positive negative neutral].include?(result.sentiment), "sentiment was #{result.sentiment.inspect}")
    check(result.score.is_a?(Integer) && (1..5).cover?(result.score), "score was #{result.score.inspect}")
    "#{result.sentiment} #{result.score}"
  }),
  Scenario.new("an optional field is a String or nil, never missing", lambda {
    result = Fixtures::Reviewer.call(review: REVIEW)
    check(result.to_h.key?(:quote), "quote was missing")
    check(result.quote.nil? || result.quote.is_a?(String), "quote was #{result.quote.inspect}")
    "quote=#{result.quote.inspect}"
  }),
  Scenario.new("nested objects and arrays of objects are typed", lambda {
    result = Fixtures::InvoiceReader.call(text: INVOICE)
    check(result.line_items.is_a?(Array) && result.line_items.all?(Data),
      "line_items were #{result.line_items.inspect}")
    check(result.line_items.all? { |item| item.quantity.is_a?(Integer) && item.unit_price.is_a?(Numeric) },
      "line items had the wrong types: #{result.line_items.inspect}")
    check(result.total.is_a?(Numeric), "total was #{result.total.inspect}")
    "#{result.invoice_number}, #{result.line_items.size} items, total #{result.total}"
  }),
  Scenario.new("squish_validate rejection retries with the conversation so far", lambda {
    instance = Fixtures::CheckedColor.new
    result = instance.call
    check(instance.checks == 2, "expected 2 validator runs, got #{instance.checks.inspect}")
    check(result.word.match?(/\A[a-z]+\z/), "word was #{result.word.inspect}")
    "second answer: #{result.word}"
  }),
  Scenario.new("squawk reports the resolved model id and token counts", lambda {
    calls = []
    hook = ->(output:, metadata:, error:) { calls << { output:, metadata:, error: } }
    Class.new(Fixtures::Reviewer) { squishling squawk: hook }.call(review: REVIEW)
    metadata = calls.first[:metadata]
    check(calls.size == 1 && calls.first[:error].nil?, "unexpected squawk calls: #{calls.inspect}")
    check(metadata[:model].to_s.start_with?("claude-"), "model was #{metadata[:model].inspect}")
    check(metadata[:usage].is_a?(Hash) && metadata[:usage][:output_tokens].is_a?(Integer),
      "usage was #{metadata[:usage].inspect}")
    "#{metadata[:model]} #{metadata[:usage].inspect}"
  }),
  Scenario.new("squishsum takes two concurrent samples, each its own claude process", lambda {
    klass = Class.new(Fixtures::Reviewer) { squishling harness: { type: :squishsum, compare: ->(*) { true } } }
    result = klass.call(review: REVIEW)
    check(result.squished?, "expected an LLM result")
    "sample accepted: #{result.sentiment}"
  }),
  Scenario.new("an ANTHROPIC_API_KEY in the environment is removed, so the call stays on the subscription", lambda {
    previous = ENV.fetch("ANTHROPIC_API_KEY", nil)
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-not-a-real-key-for-this-test"
    begin
      result = Fixtures::Reviewer.call(review: REVIEW)
    ensure
      previous ? ENV["ANTHROPIC_API_KEY"] = previous : ENV.delete("ANTHROPIC_API_KEY")
    end
    check(result.squished?, "expected an LLM result")
    "an invalid key in the environment didn't matter"
  }),
  Scenario.new("a timeout is an LLMError and stops the call promptly", lambda {
    configure({ type: :claude_code, timeout: 0.5 })
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      Fixtures::Reviewer.call(review: REVIEW)
    rescue Squishling::LLMError => e
      check(e.message.include?("longer than"), "unexpected message: #{e.message}")
    else
      raise "expected an LLMError"
    ensure
      configure
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    check(elapsed < 30, "took #{elapsed.round(1)}s")
    "gave up after #{elapsed.round(1)}s"
  }),
  Scenario.new("max_output_tokens too small is an LLMError, and the fallback takes over", lambda {
    klass = Class.new(Fixtures::Fallback) { squishling params: { max_output_tokens: 5 } }
    result = klass.call
    check(result.word == "fallback", "the fallback didn't run: #{result.to_h.inspect}")
    "answer cut off; the fallback took over"
  }),
  Scenario.new("temperature has no equivalent in Claude Code: ConfigurationError, not a fallback", lambda {
    klass = Class.new(Fixtures::Fallback) { squishling params: { temperature: 0.2 } }
    begin
      result = klass.call
    rescue Squishling::ConfigurationError => e
      check(e.message.include?("takes only the max_output_tokens"), "unexpected message: #{e.message}")
      next "rejected temperature"
    end
    raise "expected ConfigurationError, got #{result.to_h.inspect}"
  })
].freeze

def run(scenario)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  detail = scenario.block.call
  puts "  ✓ #{scenario.name} (#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)}s)" \
       "#{" — #{detail}" if detail.is_a?(String)}"
  true
rescue StandardError => e
  puts "  ✗ #{scenario.name}\n      #{e.class}: #{e.message}"
  false
end

puts "squishling-claude_code live examples (#{Squishling::ClaudeCode::VERSION}), model #{MODEL}\n\n"
failures = SCENARIOS.count { |scenario| !run(scenario) }
puts "\n#{SCENARIOS.size - failures}/#{SCENARIOS.size} passed"
exit(failures.zero? ? 0 : 1)
