# frozen_string_literal: true

module TlLinkolnClient
  class Coordination
    # One sync of a TL login at a time, across apps. Price sends do not take this lock.
    class SyncAccount < Coordination
      TTL_MS = 120_000

      class << self
        def acquire(system_id:, user_id:, owner:, ttl_ms: TTL_MS)
          acquire_lock(sync_key(system_id, user_id), owner, ttl_ms)
        end

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
