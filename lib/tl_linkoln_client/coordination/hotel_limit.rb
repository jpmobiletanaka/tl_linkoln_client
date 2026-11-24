# frozen_string_literal: true

module TlLinkolnClient
  class Coordination
    # How many TL logins may send, and how many may sync, at the same time.
    # The member is the login hash, so two apps count as one hotel.
    class HotelLimit < Coordination
      TTL_MS = 120_000
      SEND_KEY = 'tl:send_hotels'
      SYNC_KEY = 'tl:sync_hotels'

      ENTER = <<~LUA.freeze
        local now = tonumber(ARGV[1])
        local expires_at = tonumber(ARGV[2])
        local limit = tonumber(ARGV[3])
        local member = ARGV[4]
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
        if redis.call('ZSCORE', KEYS[1], member) then
          redis.call('ZADD', KEYS[1], expires_at, member)
          return 1
        end
        if redis.call('ZCARD', KEYS[1]) >= limit then
          return 0
        end
        redis.call('ZADD', KEYS[1], expires_at, member)
        return 1
      LUA

      EXTEND = <<~LUA.freeze
        local now = tonumber(ARGV[1])
        local expires_at = tonumber(ARGV[2])
        local member = ARGV[3]
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
        if not redis.call('ZSCORE', KEYS[1], member) then
          return 0
        end
        redis.call('ZADD', KEYS[1], expires_at, member)
        return 1
      LUA

      LEAVE = <<~LUA.freeze
        return redis.call('ZREM', KEYS[1], ARGV[1])
      LUA

      class << self
        def enter_send(system_id:, user_id:, limit:, ttl_ms: TTL_MS)
          enter(SEND_KEY, system_id, user_id, limit, ttl_ms)
        end

        def extend_send(system_id:, user_id:, ttl_ms: TTL_MS)
          extend(SEND_KEY, system_id, user_id, ttl_ms)
        end

        def leave_send(system_id:, user_id:)
          leave(SEND_KEY, system_id, user_id)
        end

        def enter_sync(system_id:, user_id:, limit:, ttl_ms: TTL_MS)
          enter(SYNC_KEY, system_id, user_id, limit, ttl_ms)
        end

        def extend_sync(system_id:, user_id:, ttl_ms: TTL_MS)
          extend(SYNC_KEY, system_id, user_id, ttl_ms)
        end

        def leave_sync(system_id:, user_id:)
          leave(SYNC_KEY, system_id, user_id)
        end

        private

        def enter(key, system_id, user_id, limit, ttl_ms)
          raise ArgumentError, 'limit must be positive' unless limit.to_i.positive?

          now = now_ms
          result = eval_script(
            ENTER,
            keys: [ key ],
            argv: [ now, now + ttl_ms.to_i, limit.to_i, login_id(system_id, user_id) ]
          )
          truthy?(result)
        end

        def extend(key, system_id, user_id, ttl_ms)
          now = now_ms
          result = eval_script(
            EXTEND,
            keys: [ key ],
            argv: [ now, now + ttl_ms.to_i, login_id(system_id, user_id) ]
          )
          truthy?(result)
        end

        def leave(key, system_id, user_id)
          result = eval_script(LEAVE, keys: [ key ], argv: [ login_id(system_id, user_id) ])
          result.to_i.positive?
        end
      end
    end
  end
end
