# frozen_string_literal: true

module TlLinkolnClient
  class Client
    SOCKET_ERROR_DELAY = 60
    TIMEOUT_RETRY_DELAY = 5
    RETRY_COUNT = 2
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 90
    EMPTY_RESPONSE = 'E613'

    class TlMaintenanceError < StandardError; end

    delegate :hotel_id, :sc_type, to: :sc_account

    attr_reader :retry_count

    def initialize(sc_account = nil)
      @sc_account = sc_account
      yml_path = File.expand_path('../config/urls.yml', __dir__)
      @config = YAML.safe_load(File.read(yml_path))
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

    def client
      @_client ||= ::Savon::Client.new(
        wsdl: cached_wsdl_path,
        endpoint: soap_endpoint,
        proxy: proxy,
        read_timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT,
        adapter: :net_http
      )
    end

    def cached_wsdl_path
      TlLinkolnClient::WsdlCache.ensure_local_path(wsdl, proxy: proxy)
    end

    def soap_endpoint
      wsdl.to_s.sub(/\?.*\z/, '')
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
      rescue ::Excon::Error::Socket => e
        log_errors(e, body_request, time)
        @retry_count += 1
        if retry_count < RETRY_COUNT
          sleep(SOCKET_ERROR_DELAY)
          retry
        end
        raise e
      rescue ::Excon::Error::Timeout, ::Timeout::Error => e
        log_errors(e, body_request, time)
        @retry_count += 1
        if retry_count < RETRY_COUNT
          sleep(TIMEOUT_RETRY_DELAY)
          retry
        end
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
      hash = ::Ox.load(response.to_s, mode: :hash_no_attrs, effort: :auto_define)
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
      logger.error(
        error,
        request: request.gsub(sc_account.sc_password, ''),
        time: Time.current - time,
        endpoint: soap_endpoint
      )
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

    def validate!
      @errors = []
      send(:validation) if respond_to?(:validation, true)
      raise TlLinkolnClient::Common::Error, @errors if @errors.present?
    end

    def logger
      @_logger ||= TlLinkolnClient::Common::Logger.new(:sc_client, hotel_id, Time.current.to_i)
    end

    def wsdl
      return @wsdl if @wsdl.present?

      path = self.class.name.tableize.singularize.split('/')
      path.push('wsdl')
      environment = 'test' if sc_account.blank?
      environment ||= sc_account.test_account? ? 'test' : 'production'
      path.unshift(environment)
      @wsdl = config.dig(*path)
    end
  end
end
