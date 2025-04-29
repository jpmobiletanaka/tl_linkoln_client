# frozen_string_literal: true

module TlLinkolnClient
  module Inventory
    class UpdateClient < TlLinkolnClient::Client
      SALES_STATUS = { start_sell: 1, stop_sell: 2, dont_change: 3 }.freeze
      DEFAULT_SALES_STATUS   = 3
      DEFAULT_PROCEDURE_CODE = 2

      private

      def body_request
        super do |xml|
          xml.adjustmentTarget do
            xml.adjustmentProcedureCode procedure_code
            xml.agt_code params[:agent_code]
            xml.netAgtRmTypeCode params[:room_type_code]
            xml.adjustmentDate format_date(params[:date])
            xml.remainingCount params[:count]
            xml.salesStatus sales_status
          end
        end
      end

      def procedure_code
        return if [params[:agent_code], params[:room_type_code]].any?(&:blank?)

        DEFAULT_PROCEDURE_CODE
      end

      def sales_status
        SALES_STATUS[params[:sales_status]] || DEFAULT_SALES_STATUS
      end

      def validation
        @errors << 'Invalid params set'     if procedure_code.blank?
        @errors << 'Invalid date'           unless params[:date].is_a?(Date)
        @errors << 'Invalid count'          if params[:count].blank?
        @errors << 'Invalid room type code' if params[:room_type_code].blank?
      end
    end
  end
end
