# frozen_string_literal: true

require 'digest'

module TlLinkolnClient
  # Shared Redis handle and lock helpers for the four TL-Lincoln coordination tasks.
  # The client is assigned once at boot (`Coordination.redis = ...`).
  # This class never opens a connection and does not read ENV.
  class Coordination
    class RedisNotConfigured < StandardError; end

    RELEASE_IF_OWNER = <<~LUA.freeze
      local value = redis.call('GET', KEYS[1])
      if value == ARGV[1] then
        return redis.call('DEL', KEYS[1])
      end
      return 0
    LUA

    EXTEND_IF_OWNER = <<~LUA.freeze
      local value = redis.call('GET', KEYS[1])
      if value == ARGV[1] then
        return redis.call('PEXPIRE', KEYS[1], ARGV[2])
      end
      return 0
    LUA

    class << self
      attr_accessor :redis

      def login_id(system_id, user_id)
        raise ArgumentError, 'system_id is blank' if blank?(system_id)
        raise ArgumentError, 'user_id is blank' if blank?(user_id)

        Digest::SHA256.hexdigest("#{system_id}\0#{user_id}")
      end

      def now_ms
        (Time.now.to_f * 1000).to_i
      end

      private

      def acquire_lock(key, owner, ttl_ms)
        require_owner!(owner)
        result = redis_client.set(key, owner.to_s, nx: true, px: ttl_ms.to_i)
        result == true || result == 'OK'
      end

      def extend_lock(key, owner, ttl_ms)
        require_owner!(owner)
        result = eval_script(EXTEND_IF_OWNER, keys: [ key ], argv: [ owner, ttl_ms.to_i ])
        truthy?(result)
      end

      def release_lock(key, owner)
        require_owner!(owner)
        result = eval_script(RELEASE_IF_OWNER, keys: [ key ], argv: [ owner ])
        truthy?(result)
      end

      def eval_script(script, keys:, argv:)
        redis_client.eval(script, keys: keys, argv: argv.map(&:to_s))
      end

      def redis_client
        Coordination.redis || raise(RedisNotConfigured, 'TlLinkolnClient::Coordination.redis is not set')
      end

      def require_owner!(owner)
        raise ArgumentError, 'owner is blank' if blank?(owner)
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def truthy?(value)
        value == true || value == 1 || value == '1' || value == 'OK'
      end
    end
  end
end

require_relative 'coordination/room_lock'
require_relative 'coordination/sync_account'
require_relative 'coordination/hotel_limit'
require_relative 'coordination/slots'
require_relative 'coordination/lease'
