# frozen_string_literal: true

module TlLinkolnClient
  class Client < TlLinkolnClient::Common::Client
    SOCKET_ERROR_DELAY = 60
    RETRY_COUNT = 2
    TIMEOUT = 90
    EMPTY_RESPONSE = "E613"

    def wsdl
      return @wsdl if @wsdl.present?

      path = self.class.name.tableize.singularize.split('/')
      path.push('wsdl')
      environment = 'test' if sc_account.blank?
      environment ||= sc_account.test_account? ? 'test' : 'production'
      path.unshift(environment)
      @wsdl = config.dig(*path)
    end

    protected

    def client
      @_client ||= ::Savon::Client.new(wsdl: wsdl, proxy: proxy, read_timeout: TIMEOUT, open_timeout: TIMEOUT)
    end

    def proxy
      return unless sc_account.test_account?

      ENV['SC_PROXY']
    end

    def make_response
      @retry_count = 0
      time = Time.current
      begin
        response = client.call(:execute, message: body_request)
        parse_response_ox(response)
      rescue Excon::Error::Timeout => e
        log_errors(e, body_request, time)
        raise TlLinkolnClient::Common::Error, e.message
      rescue Excon::Error::Socket => e
        log_errors(e, body_request, time)
        sleep(SOCKET_ERROR_DELAY)
        @retry_count += 1
        retry if retry_count < RETRY_COUNT
        raise e
      rescue StandardError => e
        log_errors(e, body_request, time)
        raise e
      end
    end

    def parse_response(response)
      hash = Hash.from_xml(Nokogiri::XML(response.to_s).to_s).deep_symbolize_keys
      hash.dig(:Envelope, :Body, :executeResponse, :return)
    end

    def parse_response_ox(response)
      hash = Ox.load(response.to_s, mode: :hash_no_attrs, effort: :auto_define)
      hash.dig(:'S:Envelope', :'S:Body', :'ns2:executeResponse', :return)
    end

    def formatted_response(data)
      {
        success: data.dig(:commonResponse, :isSuccess),
        error: data.dig(:commonResponse, :errorDescription),
        response: data
      }
    end

    def log_errors(error, request, time)
      logger.error(error, request: request.gsub(sc_account.sc_password, ''), time: Time.current - time)
    end

    def format_date(date)
      date.to_date.strftime('%Y%m%d')
    end

    def body_request
      Nokogiri::XML::Builder.new do |xml|
        xml.arg0 do
          xml.commonRequest do
            xml.systemId sc_account.sc_system_id
            xml.pmsUserId sc_account.sc_user_id
            xml.pmsPassword sc_account.sc_password
          end
          yield(xml) if block_given?
        end
      end.doc.root.to_xml
    end

    def check_response(data)
      return if data[:error].blank?

      if data.dig(:response, :commonResponse, :failureReason) == EMPTY_RESPONSE
        raise TlLinkolnClient::Common::EmptyError, "Message: #{data[:error]}, params: #{params}"
      end

      raise TlLinkolnClient::Common::Error, "Message: #{data[:error]}, params: #{params}"
    end
  end
end
