# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe Squishling::ClaudeCode do
  it "has a version" do
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  describe ".register" do
    after { described_class.register }

    it "registers the adapter again after Squishling.reset_adapters! forgot it, and is harmless when it is there" do
      Squishling.reset_adapters!
      expect(Squishling.adapters).not_to include(:claude_code)

      2.times { described_class.register }

      expect(Squishling.adapters).to include(:claude_code)
    end
  end

  # A subprocess with a stand-in for a Squishling that predates pluggable adapters: loading the entry file again in
  # this process would also reset its coverage counters.
  it "refuses to load on a Squishling without pluggable adapters, naming the version it found" do
    Dir.mktmpdir do |old_squishling|
      File.write(File.join(old_squishling, "squishling.rb"), "module Squishling; VERSION = '0.0.1'; end")

      output, status = Open3.capture2e({ "RUBYOPT" => nil }, RbConfig.ruby, "-I", old_squishling,
        "-I", File.expand_path("../../lib", __dir__), "-e", 'require "squishling/claude_code"')

      expect(status).not_to be_success
      expect(output).to include("LoadError").and include("pluggable adapters").and include("Squishling 0.0.1")
    end
  end
end
