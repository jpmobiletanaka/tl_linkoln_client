module TlLinkolnClient
  module PlanGroups
    class FetchClient < TlLinkolnClient::Client
      DEFAULT_PROCEDURE_CODE = 2

      private

      def body_request
        super do |xml|
          xml.extractionCondition do
            xml.extractionProcedureCode DEFAULT_PROCEDURE_CODE
          end
        end
      end
    end
  end
end