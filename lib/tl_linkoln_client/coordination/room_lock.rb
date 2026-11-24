# frozen_string_literal: true

module TlLinkolnClient
  class Coordination
    # One room (TL room type group code) at a time for a price send or a price fetch.
    # A send registers a wait marker first, so a sync does not take the room ahead of it.
    class RoomLock < Coordination
      TTL_MS = 120_000

      REGISTER_WAIT = <<~LUA.freeze
        local now = tonumber(ARGV[1])
        local expires_at = tonumber(ARGV[2])
        local owner = ARGV[3]
        local ttl = tonumber(ARGV[4])
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
        redis.call('ZADD', KEYS[1], expires_at, owner)
        redis.call('PEXPIRE', KEYS[1], ttl)
        return 1
      LUA

      WAITING = <<~LUA.freeze
        local now = tonumber(ARGV[1])
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
        return redis.call('ZCARD', KEYS[1])
      LUA

      CLEAR_WAIT = <<~LUA.freeze
        return redis.call('ZREM', KEYS[1], ARGV[1])
      LUA

      # Fails when a send is already waiting on this room, then SET NX PX.
      ACQUIRE_FOR_SYNC = <<~LUA.freeze
        local now = tonumber(ARGV[3])
        redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', now)
        if redis.call('ZCARD', KEYS[2]) > 0 then
          return 0
        end
        local result = redis.call('SET', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2])
        if result then
          return 1
        end
        return 0
      LUA

      class << self
        def acquire(system_id:, user_id:, room_code:, owner:, ttl_ms: TTL_MS)
          acquire_lock(room_key(system_id, user_id, room_code), owner, ttl_ms)
        end

        def extend(system_id:, user_id:, room_code:, owner:, ttl_ms: TTL_MS)
          extend_lock(room_key(system_id, user_id, room_code), owner, ttl_ms)
        end

        def release(system_id:, user_id:, room_code:, owner:)
          release_lock(room_key(system_id, user_id, room_code), owner)
        end

        def acquire_for_sync(system_id:, user_id:, room_code:, owner:, ttl_ms: TTL_MS)
          require_owner!(owner)
          result = eval_script(
            ACQUIRE_FOR_SYNC,
            keys: [ room_key(system_id, user_id, room_code), wait_key(system_id, user_id, room_code) ],
            argv: [ owner, ttl_ms.to_i, now_ms ]
          )
          truthy?(result)
        end

        def register_send_wait(system_id:, user_id:, room_code:, owner:, ttl_ms: TTL_MS)
          require_owner!(owner)
          now = now_ms
          eval_script(
            REGISTER_WAIT,
            keys: [ wait_key(system_id, user_id, room_code) ],
            argv: [ now, now + ttl_ms.to_i, owner, ttl_ms.to_i ]
          )
          true
        end

        def send_waiting?(system_id:, user_id:, room_code:)
          result = eval_script(
            WAITING,
            keys: [ wait_key(system_id, user_id, room_code) ],
            argv: [ now_ms ]
          )
          result.to_i.positive?
        end

        def clear_send_wait(system_id:, user_id:, room_code:, owner:)
          require_owner!(owner)
          result = eval_script(
            CLEAR_WAIT,
            keys: [ wait_key(system_id, user_id, room_code) ],
            argv: [ owner ]
          )
          result.to_i.positive?
        end

        private

        def room_key(system_id, user_id, room_code)
          "tl:room:{#{login_id(system_id, user_id)}}:#{room_code(room_code)}"
        end

        def wait_key(system_id, user_id, room_code)
          "tl:room_wait:{#{login_id(system_id, user_id)}}:#{room_code(room_code)}"
        end

        def room_code(room_code)
          raise ArgumentError, 'room_code is blank' if blank?(room_code)

          room_code
        end
      end
    end
  end
end
