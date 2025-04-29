# frozen_string_literal: true

module TlLinkolnClient
  module RoomTypeGroups
    class FetchClient < TlLinkolnClient::Client
      PROCEDURE_CODE = 0

      private

      def body_request
        super do |xml|
          xml.extractionCondition do
            xml.extractionProcedureCode PROCEDURE_CODE
          end
        end
      end
    end
  end
end
