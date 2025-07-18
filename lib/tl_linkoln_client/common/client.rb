# frozen_string_literal: true

module TlLinkolnClient
  module Common
    class Client
      delegate :hotel_id, :sc_type, to: :sc_account

      attr_reader :retry_count

      def initialize(sc_account = nil)
        @sc_account = sc_account
        yml_path    = File.expand_path("../../config/urls.yml", __dir__)
        @config     = YAML.safe_load(File.read(yml_path))
      end

      def call(params = nil)
        @params = params
        validate!
        response = make_response
        data = formatted_response(response)
        check_response(data)
        data[:response]
      end

      private

      attr_reader :params, :sc_account, :config

      def formatted_response(_)
        raise NotImplementedError
      end

      def make_response
        raise NotImplementedError
      end

      def validate!
        @errors = []
        send(:validation) if respond_to?(:validation, true)
        raise TlLinkolnClient::Common::Error, @errors if @errors.present?
      end

      def check_response(data)
        raise TlLinkolnClient::Common::Error, "Message: #{data[:error]}, params: #{params}" if data[:success].blank?
      end

      def logger
        @_logger ||= TlLinkolnClient::Common::Logger.new(:sc_client, hotel_id, Time.current.to_i)
      end
    end
  end
end
