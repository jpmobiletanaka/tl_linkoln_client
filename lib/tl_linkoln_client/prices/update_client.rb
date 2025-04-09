module TlLinkolnClient
  module Prices
    class UpdateClient < TlLinkolnClient::Client
      SALES_STATUS = { start_sell: 1, stop_sell: 2, dont_change: 3 }.freeze
      DEFAULT_SALES_STATUS   = 3
      DEFAULT_PROCEDURE_CODE = 1

      def call(params = nil)
        if !Rails.env.production? && test_hotel_ids.exclude?(sc_account.hotel_id)
          raise TlLinkolnClient::Common::Error, 'You can not send prices from non production'
        end

        super(params)
      end

      private

      def test_hotel_ids
        ENV['TEST_HOTEL_IDS'].to_s.split(',').map(&:to_i)
      end

      def body_request
        super do |xml|
          xml.requestId params[:request_id]
          params[:price_data].each do |param|
            xml.adjustmentTarget do
              xml.adjustmentProcedureCode DEFAULT_PROCEDURE_CODE
              xml.adjustmentDate format_date(param[:date])
              xml.planGroupCode param[:plan_group_code]
              xml.salesStatus DEFAULT_SALES_STATUS
              param.keys.grep(/price_range/).each do |key|
                xml.send(key.camelize(:lower), param[key])
              end
            end
          end
        end
      end

      def check_response(_); end

      def validation
        @errors << 'Invalid params set' if params[:price_data].blank?
      end
    end
  end
end