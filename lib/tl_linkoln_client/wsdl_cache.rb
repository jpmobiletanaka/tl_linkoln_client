# frozen_string_literal: true

require 'fileutils'
require 'open-uri'
require 'uri'

module TlLinkolnClient
  # Downloads remote WSDL once into tmp and reuses the local file for later Savon clients.
  class WsdlCache
    DOWNLOAD_OPEN_TIMEOUT = 10
    DOWNLOAD_READ_TIMEOUT = 30
    TTL = 24 * 60 * 60

    def self.ensure_local_path(url, proxy: nil)
      new(url, proxy: proxy).path
    end

    def initialize(url, proxy: nil)
      @url = url.to_s
      @proxy = proxy
    end

    def path
      return url unless remote?

      ensure_cached!
      cache_file
    end

    private

    attr_reader :url, :proxy

    def remote?
      url.match?(%r{\Ahttps?://}i)
    end

    def cache_dir
      base =
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join('tmp').to_s
        else
          Dir.tmpdir
        end
      File.join(base, 'tl_linkoln_wsdl')
    end

    # e.g. www.tl-lincoln.net_NetPriceBulkAdjustmentService.xml
    def cache_file
      uri = URI.parse(url)
      host = uri.host.presence || 'unknown'
      service = File.basename(uri.path).presence || 'wsdl'
      File.join(cache_dir, "#{host}_#{service}.xml")
    end

    def cached?
      File.file?(cache_file) && !File.zero?(cache_file)
    end

    def fresh?
      cached? && File.mtime(cache_file) > Time.now - TTL
    end

    def ensure_cached!
      return if fresh?

      FileUtils.mkdir_p(cache_dir)
      File.open("#{cache_file}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        return if fresh?

        begin
          download!
        rescue StandardError
          raise unless cached?
          # Keep stale file when TL is unreachable during refresh.
        end
      end
    end

    def download!
      tmp = nil
      options = {
        open_timeout: DOWNLOAD_OPEN_TIMEOUT,
        read_timeout: DOWNLOAD_READ_TIMEOUT
      }
      options[:proxy] = proxy if proxy.present?

      body = URI.open(url, **options).read
      tmp = "#{cache_file}.tmp.#{Process.pid}"
      File.write(tmp, body)
      File.rename(tmp, cache_file)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
