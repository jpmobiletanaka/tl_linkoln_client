# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'tl_linkoln_client/coordination'
require_relative 'support/fake_redis'
require_relative 'support/coordination_context'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.disable_monkey_patching!
  config.order = :random
end
