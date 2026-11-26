# frozen_string_literal: true

require 'securerandom'

module TlLinkolnClient
  class Coordination
    # One sync of a TL login at a time, across apps, and at most MAX_PARALLEL logins syncing at once
    # (`limit:` overrides it, mainly for specs). Price sends do not take this lock.
    #
    # One Redis script takes the login and a capacity slot together, so the two never disagree:
    # - the login is held by another owner: AlreadyLocked;
    # - all slots are held by other logins: NoFreeSlots;
    # - otherwise the login is taken with its owner and counted as one slot.
    # Extending and releasing are scripts too, and they check the owner.
    #
    # No background renewal thread is started: the caller extends the hold explicitly via
    # Guard#assert_locked! before each step that talks to TL (or writes sync results). TTL_MS covers
    # one long step. There is no limit on the total duration: a sync that keeps reaching its checks
    # keeps its hold.
    class SyncAccount < Coordination
      TTL_MS = 600_000 # 10 minutes per step; reset on every Guard#assert_locked!

      # How many TL logins may sync at the same time across all apps. One value for everyone, so apps cannot
      # disagree. Today in revenue: 15 processes of the TL sync queue (3 replicas x 5) plus 1 process of the
      # manual queue, so a manual sync always finds a free slot.
      MAX_PARALLEL = 16

      # Both keys share the hash tag {tl:sync}, so the scripts are valid on Redis Cluster too.
      SLOTS_KEY = 'tl:{sync}:slots'   # ZSET: login => expires_at. Its size is the number of busy slots.
      OWNERS_KEY = 'tl:{sync}:owners' # HASH: login => owner
      LAST_TAKEN_KEY = 'tl:{sync}:last_taken' # string: ms timestamp of the last slot taken by any app

      # Raised by .with_lock when another owner holds the login.
      class AlreadyLocked < StandardError; end

      # Raised by .with_lock when all slots are held by other logins.
      class NoFreeSlots < StandardError; end

      # Raised by Guard#assert_locked! when the hold is lost.
      class Lost < StandardError; end

      # Drops expired logins from both keys. Shared by every script below.
      PURGE = <<~LUA
        local expired = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
        for _, login in ipairs(expired) do
          redis.call('HDEL', KEYS[2], login)
        end
        redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
      LUA

      # ARGV: now, expires_at, limit, login, owner. Returns 1 (taken), 0 (login held), -1 (no free slot).
      # A taken slot also stamps LAST_TAKEN_KEY with `now`, so every app can see that the queue is moving.
      ACQUIRE_SCRIPT = (PURGE + <<~LUA).freeze
        if redis.call('HEXISTS', KEYS[2], ARGV[4]) == 1 then return 0 end
        if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[3]) then return -1 end
        redis.call('HSET', KEYS[2], ARGV[4], ARGV[5])
        redis.call('ZADD', KEYS[1], ARGV[2], ARGV[4])
        redis.call('SET', KEYS[3], ARGV[1])
        return 1
      LUA

      # ARGV: now, expires_at, login, owner. Returns 1 when extended, 0 when not held by this owner.
      EXTEND_SCRIPT = (PURGE + <<~LUA).freeze
        if redis.call('HGET', KEYS[2], ARGV[3]) ~= ARGV[4] then return 0 end
        redis.call('ZADD', KEYS[1], ARGV[2], ARGV[3])
        return 1
      LUA

      # ARGV: login, owner. Removes the hold only when this owner has it.
      RELEASE_SCRIPT = <<~LUA
        if redis.call('HGET', KEYS[2], ARGV[1]) ~= ARGV[2] then return 0 end
        redis.call('HDEL', KEYS[2], ARGV[1])
        redis.call('ZREM', KEYS[1], ARGV[1])
        return 1
      LUA

      # Handed to the block of .with_lock. Call #assert_locked! before each step that talks to TL;
      # each call extends the hold in Redis.
      class Guard
        def initialize(lease)
          @lease = lease
        end

        def renew!
          @lease.renew!
        end

        def lost?
          @lease.lost?
        end

        def assert_locked!
          raise Lost, 'sync lock lost' unless renew!
        end
      end

      class << self
        # Holds the login and one of the slots while the block runs. Raises AlreadyLocked or NoFreeSlots
        # without running the block. Inside the block, `guard.assert_locked!` extends both before each step.
        # Always released on exit if still ours.
        def with_lock(system_id:, user_id:, owner: SecureRandom.uuid, ttl_ms: TTL_MS, limit: MAX_PARALLEL)
          case acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit, ttl_ms: ttl_ms)
          when :already then raise AlreadyLocked, 'TL sync is already running for this login'
          when :full then raise NoFreeSlots, "all #{limit} TL sync slots are busy"
          end

          # Lease.new (not Lease.start): explicit renewals only, no background thread.
          # Infinite deadline: the hold is lost only when a renewal is refused or raises.
          lease = Lease.new(max_duration: Float::INFINITY) do
            renew(system_id: system_id, user_id: user_id, owner: owner, ttl_ms: ttl_ms)
          end
          begin
            yield Guard.new(lease)
          ensure
            release(system_id: system_id, user_id: user_id, owner: owner)
          end
        end

        # Returns :ok (login and slot taken), :already (login held by another owner) or :full (no free slot).
        def acquire(system_id:, user_id:, owner:, ttl_ms: TTL_MS, limit: MAX_PARALLEL)
          require_owner!(owner)
          require_positive_ttl!(ttl_ms)
          raise ArgumentError, 'limit must be positive' unless limit.to_i.positive?

          now = now_ms
          result = eval_script(
            ACQUIRE_SCRIPT,
            keys: [SLOTS_KEY, OWNERS_KEY, LAST_TAKEN_KEY],
            argv: [now, now + ttl_ms.to_i, limit.to_i, login_id(system_id, user_id), owner]
          )
          case result.to_i
          when 1 then :ok
          when 0 then :already
          else :full
          end
        end

        # When a slot was last taken by any app (revenue or metro-trail), as a Time. Nil when no slot has been
        # taken since LAST_TAKEN_KEY was introduced. Only refused attempts do not move it.
        def last_taken_at
          value = redis_client.get(LAST_TAKEN_KEY)
          return nil if value.nil?

          Time.at(value.to_i / 1000.0)
        end

        # Moves the expiry of the hold forward. False when the hold is not ours any more (expired or taken over);
        # an expired hold is not re-created.
        def renew(system_id:, user_id:, owner:, ttl_ms: TTL_MS)
          require_owner!(owner)
          require_positive_ttl!(ttl_ms)

          now = now_ms
          result = eval_script(
            EXTEND_SCRIPT,
            keys: [SLOTS_KEY, OWNERS_KEY],
            argv: [now, now + ttl_ms.to_i, login_id(system_id, user_id), owner]
          )
          truthy?(result)
        end

        def release(system_id:, user_id:, owner:)
          require_owner!(owner)

          result = eval_script(RELEASE_SCRIPT, keys: [SLOTS_KEY, OWNERS_KEY], argv: [login_id(system_id, user_id), owner])
          truthy?(result)
        end
      end
    end
  end
end
