# frozen_string_literal: true

module TlLinkolnClient
  module Prices
    class FetchClient < TlLinkolnClient::Client
      DEFAULT_PROCEDURE_CODE = 2
      PROCEDURE_CODE_FOR_PLAN_GROUP = 3

      private

      def body_request
        super do |xml|
          xml.extractionCondition do
            xml.extractionProcedureCode procedure_code
            xml.searchDurationFrom format_date(params[:start_date])
            xml.searchDurationTo format_date(params[:end_date])
            xml.planGroupCode params[:plan_group_code] if params[:plan_group_code].present?
          end
        end
      end

      def procedure_code
        return if [params[:start_date], params[:end_date]].any?(&:blank?)
        return PROCEDURE_CODE_FOR_PLAN_GROUP if params[:plan_group_code].present?

        DEFAULT_PROCEDURE_CODE
      end

      def validation
        @errors << 'Invalid params set' if procedure_code.blank?
        @errors << 'Invalid start_date' if params[:start_date].blank?
        @errors << 'Invalid end_date'   if params[:end_date].blank?
      end
    end
  end
end
