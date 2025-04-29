# frozen_string_literal: true

module TlLinkolnClient
  module Common
    class Logger
      def initialize(type, hotel_id, sync_id, additional_params = {})
        @type = type
        @params = {
          type: type,
          hotel_id: hotel_id,
          sync_id: sync_id
        }.merge(additional_params)
      end

      def info(log_info)
        logger.info(params.merge(log_info))
      end

      def error(error, log_info = {})
        logger.error(
          params.merge(type: "#{type}_error", status: :error, error: error.message, trace: error.backtrace)
                .merge(log_info)
        )
      end

      private

      attr_reader :type, :params

      def logger
        @_logger ||= Rails.logger
      end
    end
  end
end
