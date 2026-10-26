# frozen_string_literal: true

require "simplecov"
require "tempfile"
require "timeout"
require "squishling/claude_code"

module AdapterHelpers
  # An Adapter::Request for specs that call the adapter directly.
  def adapter_request(schema: nil, **overrides)
    schema ||= { "name" => "Response", "strict" => true,
                 "schema" => { "$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object",
                               "properties" => { "label" => { "type" => "string" } },
                               "required" => ["label"], "additionalProperties" => false } }
    Squishling::Adapter::Request.new(label: "Klass#call", model: "haiku", provider: nil, instructions: "Classify.",
      messages: [{ role: :user, content: "hi" }], schema:, params: {}, **overrides)
  end
end

RSpec.configure do |config|
  config.include AdapterHelpers
  config.after { Squishling.reset_config! }
end
