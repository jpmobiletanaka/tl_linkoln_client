# frozen_string_literal: true

module TlLinkolnClient
  module Common
    class Error < StandardError
      def initialize(message)
        message = message.join('. ') if message.is_a? Array
        super(message)
      end
    end
  end
end
