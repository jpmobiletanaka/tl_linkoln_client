# frozen_string_literal: true

require 'securerandom'

module TlLinkolnClient
  class Coordination
    # One sync of a TL login at a time, across apps. Price sends do not take this lock.
    #
    # No background renewal thread is started: the caller extends the lock explicitly via
    # Guard#assert_locked! before each step that talks to TL (or writes sync results). TTL_MS covers
    # one long step (SOAP timeouts + retry delay + DB import). There is no limit on the total duration:
    # a sync that keeps reaching its checks keeps the lock.
    class SyncAccount < Coordination
      TTL_MS = 600_000 # 10 minutes per step; reset on every Guard#assert_locked!

      # Raised by .with_lock when another owner holds the login.
      class AlreadyLocked < StandardError; end

      # Raised by Guard#assert_locked! when the lock is lost.
      class Lost < StandardError; end

      # Handed to the block of .with_lock. Call #assert_locked! before each step that talks to TL;
      # each call extends the lock in Redis.
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
        # Holds the login lock while the block runs (without starting a background thread).
        # Raises AlreadyLocked when the login is taken. Inside the block, call `guard.assert_locked!`
        # to verify and extend the lock before each step. Always released on exit if still ours.
        def with_lock(system_id:, user_id:, owner: SecureRandom.uuid, ttl_ms: TTL_MS)
          unless acquire(system_id: system_id, user_id: user_id, owner: owner, ttl_ms: ttl_ms)
            raise AlreadyLocked, 'TL sync is already running for this login'
          end

          # Lease.new (not Lease.start): explicit renewals only, no background thread.
          # Infinite deadline: the lock is lost only when a renewal is refused or raises.
          lease = Lease.new(max_duration: Float::INFINITY) do
            extend(system_id: system_id, user_id: user_id, owner: owner, ttl_ms: ttl_ms)
          end
          begin
            yield Guard.new(lease)
          ensure
            release(system_id: system_id, user_id: user_id, owner: owner)
          end
        end

        def acquire(system_id:, user_id:, owner:, ttl_ms: TTL_MS)
          acquire_lock(sync_key(system_id, user_id), owner, ttl_ms)
        end

        # Note: this overrides Module#extend on this class. Use it with keyword arguments only.
        def extend(system_id:, user_id:, owner:, ttl_ms: TTL_MS)
          extend_lock(sync_key(system_id, user_id), owner, ttl_ms)
        end

        def release(system_id:, user_id:, owner:)
          release_lock(sync_key(system_id, user_id), owner)
        end

        private

        def sync_key(system_id, user_id)
          "tl:sync_account:#{login_id(system_id, user_id)}"
        end
      end
    end
  end
end
