# frozen_string_literal: true

require 'savon'

Dir[File.join(__dir__, 'tl_linkoln_client/common/*.rb')].sort.each { |file| require_relative file }
Dir[File.join(__dir__, 'tl_linkoln_client/**/*.rb')].sort.each { |file| require_relative file }
