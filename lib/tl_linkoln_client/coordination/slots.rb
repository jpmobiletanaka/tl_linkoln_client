# frozen_string_literal: true

module TlLinkolnClient
  class Coordination
    # Remaining numberOfAcceptableProcess for one TL login.
    #
    # - #take consumes a slot and reserves it for its owner until #release_reservation,
    #   i.e. until the request to TL is over. #extend_reservation keeps the reservation alive meanwhile.
    # - #claim_refresh takes the refresh mutex only when the balance is empty and no reservation is in flight,
    #   so a refresh never reads a count that is missing a request TL has not yet seen.
    # - #replace_if_empty writes the API number only while the balance is empty and
    #   the caller still holds the refresh mutex. The check and the write are one atomic Lua step.
    class Slots < Coordination
      # Held for one NumberOfPriceRequests call, including SOAP timeouts and retries (up to ~260 s).
      # Nothing renews it. A dead owner frees it after this time.
      REFRESH_TTL_MS = 300_000

      # How long a written balance stays valid. TL's quota window is unknown, so this is a
      # conservative default; pass `ttl_ms:` to #replace_if_empty to override it.
      BALANCE_TTL_MS = 120_000

      # Covers one request to TL: up to 160 s (10 s open + 90 s read + 60 s socket retry delay) between two
      # attempts. #extend_reservation runs before each attempt. A dead owner frees it after this time.
      INFLIGHT_TTL_MS = 240_000

      # KEYS[1] - slots balance, KEYS[2] - in-flight reservations (ZSET owner -> expires_at)
      # ARGV[1] - now, ARGV[2] - reservation expires_at, ARGV[3] - owner, ARGV[4] - in-flight key ttl
      TAKE = <<~LUA.freeze
        local n = tonumber(redis.call('GET', KEYS[1]) or '0')
        if n <= 0 then
          return 0
        end
        redis.call('DECR', KEYS[1])
        redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[1])
        redis.call('ZADD', KEYS[2], ARGV[2], ARGV[3])
        redis.call('PEXPIRE', KEYS[2], ARGV[4])
        return 1
      LUA

      # KEYS[1] - refresh mutex, KEYS[2] - in-flight reservations, KEYS[3] - slots balance
      # ARGV[1] - owner, ARGV[2] - mutex ttl in ms, ARGV[3] - now
      # A refresh is allowed only when the balance is empty and nothing is in flight.
      CLAIM_REFRESH = <<~LUA.freeze
        local n = tonumber(redis.call('GET', KEYS[3]) or '0')
        if n > 0 then
          return 0
        end
        redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[3])
        if redis.call('ZCARD', KEYS[2]) > 0 then
          return 0
        end
        if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then
          return 1
        end
        return 0
      LUA

      # KEYS[1] - in-flight reservations, ARGV[1] - owner
      RELEASE_RESERVATION = <<~LUA.freeze
        return redis.call('ZREM', KEYS[1], ARGV[1])
      LUA

      # KEYS[1] - in-flight reservations
      # ARGV[1] - now, ARGV[2] - new expires_at, ARGV[3] - owner, ARGV[4] - in-flight key ttl
      # Extends only a live reservation of this owner. An expired or released one is not re-created.
      EXTEND_RESERVATION = <<~LUA.freeze
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
        if not redis.call('ZSCORE', KEYS[1], ARGV[3]) then
          return 0
        end
        redis.call('ZADD', KEYS[1], ARGV[2], ARGV[3])
        redis.call('PEXPIRE', KEYS[1], ARGV[4])
        return 1
      LUA

      # KEYS[1] - slots balance, KEYS[2] - refresh mutex
      # ARGV[1] - count from API, ARGV[2] - owner, ARGV[3] - balance ttl in ms
      # Returns -1 when the caller no longer owns the refresh mutex (nothing is written).
      REPLACE_IF_EMPTY = <<~LUA.freeze
        if redis.call('GET', KEYS[2]) ~= ARGV[2] then
          return -1
        end
        local n = tonumber(redis.call('GET', KEYS[1]) or '0')
        if n > 0 then
          return n
        end
        local count = tonumber(ARGV[1])
        if count < 0 then
          count = 0
        end
        redis.call('SET', KEYS[1], count, 'PX', ARGV[3])
        return count
      LUA

      class << self
        # Returns nil when there is no balance: TL has not reported one yet, or it expired (BALANCE_TTL_MS).
        def read(system_id:, user_id:)
          value = redis_client.get(slots_key(system_id, user_id))
          return nil if value.nil?

          value.to_i
        end

        # Atomically consumes one slot and reserves it for `owner` until #release_reservation.
        # False when the balance is missing or zero; nothing is reserved then.
        def take(system_id:, user_id:, owner:)
          require_owner!(owner)
          now = now_ms
          result = eval_script(
            TAKE,
            keys: [ slots_key(system_id, user_id), inflight_key(system_id, user_id) ],
            argv: [ now, now + INFLIGHT_TTL_MS, owner, INFLIGHT_TTL_MS ]
          )
          truthy?(result)
        end

        # Ends the reservation made by #take for `owner`. Call it once the request to TL is over.
        def release_reservation(system_id:, user_id:, owner:)
          require_owner!(owner)
          result = eval_script(RELEASE_RESERVATION, keys: [ inflight_key(system_id, user_id) ], argv: [ owner ])
          result.to_i.positive?
        end

        # Keeps a reservation alive. False when it is already gone (expired or released): it is not re-created.
        def extend_reservation(system_id:, user_id:, owner:, ttl_ms: INFLIGHT_TTL_MS)
          require_owner!(owner)
          now = now_ms
          result = eval_script(
            EXTEND_RESERVATION,
            keys: [ inflight_key(system_id, user_id) ],
            argv: [ now, now + ttl_ms.to_i, owner, ttl_ms.to_i ]
          )
          truthy?(result)
        end

        # Writes the API balance only while the stored balance is empty and `owner`
        # still holds the refresh mutex (see #claim_refresh). The balance expires after `ttl_ms`.
        # Returns the balance left in Redis, or nil when the mutex is no longer owned by `owner`.
        def replace_if_empty(system_id:, user_id:, count:, owner:, ttl_ms: BALANCE_TTL_MS)
          require_owner!(owner)
          raise ArgumentError, 'ttl_ms must be positive' unless ttl_ms.to_i.positive?

          result = eval_script(
            REPLACE_IF_EMPTY,
            keys: [ slots_key(system_id, user_id), mutex_key(system_id, user_id) ],
            argv: [ count.to_i, owner, ttl_ms.to_i ]
          ).to_i
          result.negative? ? nil : result
        end

        # Takes the refresh mutex only when the balance is empty and no send holds a reservation.
        def claim_refresh(system_id:, user_id:, owner:, ttl_ms: REFRESH_TTL_MS)
          require_owner!(owner)
          result = eval_script(
            CLAIM_REFRESH,
            keys: [ mutex_key(system_id, user_id), inflight_key(system_id, user_id), slots_key(system_id, user_id) ],
            argv: [ owner, ttl_ms.to_i, now_ms ]
          )
          truthy?(result)
        end

        def release_refresh(system_id:, user_id:, owner:)
          release_lock(mutex_key(system_id, user_id), owner)
        end

        private

        def slots_key(system_id, user_id)
          "tl:slots:{#{login_id(system_id, user_id)}}"
        end

        def mutex_key(system_id, user_id)
          "tl:slots_mutex:{#{login_id(system_id, user_id)}}"
        end

        def inflight_key(system_id, user_id)
          "tl:slots_inflight:{#{login_id(system_id, user_id)}}"
        end
      end
    end
  end
end
