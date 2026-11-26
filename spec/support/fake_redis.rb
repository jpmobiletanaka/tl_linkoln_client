# frozen_string_literal: true

# In-memory stand-in for the Redis commands Coordination sends.
# Expiry is driven by #now_ms so specs do not sleep.
class FakeRedis
  attr_accessor :now_ms

  def initialize
    @strings = {}
    @sets = {}
    @hashes = {}
    @now_ms = (Time.now.to_f * 1000).to_i
  end

  def set(key, value, nx: false, px: nil)
    purge_string(key)
    return false if nx && @strings.key?(key)

    @strings[key] = { value: value.to_s, expires_at: px ? now_ms + px.to_i : nil }
    true
  end

  def get(key)
    purge_string(key)
    @strings[key]&.fetch(:value)
  end

  def decr(key)
    purge_string(key)
    value = (@strings[key]&.fetch(:value) || '0').to_i - 1
    expires_at = @strings[key]&.fetch(:expires_at)
    @strings[key] = { value: value.to_s, expires_at: expires_at }
    value
  end

  def del(key)
    @strings.delete(key) ? 1 : 0
  end

  def pexpire(key, ttl_ms)
    purge_string(key)
    return 0 unless @strings.key?(key)

    @strings[key][:expires_at] = now_ms + ttl_ms.to_i
    1
  end

  def eval(script, keys:, argv:)
    coordination = TlLinkolnClient::Coordination
    case script
    when coordination::RELEASE_IF_OWNER
      release_if_owner(keys[0], argv[0])
    when coordination::EXTEND_IF_OWNER
      extend_if_owner(keys[0], argv[0], argv[1])
    when coordination::Slots::TAKE
      take_slot(keys[0], keys[1], argv[0], argv[1], argv[2], argv[3])
    when coordination::Slots::CLAIM_REFRESH
      claim_refresh_slots(keys[0], keys[1], keys[2], argv[0], argv[1], argv[2])
    when coordination::Slots::RELEASE_RESERVATION
      zrem(keys[0], argv[0])
    when coordination::Slots::EXTEND_RESERVATION
      extend_reservation_slot(keys[0], argv[0], argv[1], argv[2], argv[3])
    when coordination::Slots::REPLACE_IF_EMPTY
      replace_slots_if_empty(keys[0], keys[1], argv[0], argv[1], argv[2])
    when coordination::RoomLock::REGISTER_WAIT
      register_wait(keys[0], argv[0], argv[1], argv[2], argv[3])
    when coordination::RoomLock::WAITING
      waiting(keys[0], argv[0])
    when coordination::RoomLock::CLEAR_WAIT
      zrem(keys[0], argv[0])
    when coordination::RoomLock::ACQUIRE_FOR_SYNC
      acquire_room_for_sync(keys[0], keys[1], argv[0], argv[1], argv[2])
    when coordination::SyncAccount::ACQUIRE_SCRIPT
      sync_acquire(keys[0], keys[1], argv[0], argv[1], argv[2], argv[3], argv[4])
    when coordination::SyncAccount::EXTEND_SCRIPT
      sync_extend(keys[0], keys[1], argv[0], argv[1], argv[2], argv[3])
    when coordination::SyncAccount::RELEASE_SCRIPT
      sync_release(keys[0], keys[1], argv[0], argv[1])
    else
      raise ArgumentError, 'unknown script'
    end
  end

  def string_keys
    @strings.keys.select { |key| get(key) }
  end

  private

  def release_if_owner(key, owner)
    return 0 unless get(key) == owner

    del(key)
  end

  def extend_if_owner(key, owner, ttl_ms)
    return 0 unless get(key) == owner

    pexpire(key, ttl_ms)
  end

  def take_slot(key, inflight, now, expires_at, owner, inflight_ttl_ms)
    n = (get(key) || '0').to_i
    return 0 if n <= 0

    decr(key)
    zremrangebyscore(inflight, now)
    zadd(inflight, expires_at, owner)
    @sets[inflight][:expires_at] = now_ms + inflight_ttl_ms.to_i
    1
  end

  def extend_reservation_slot(inflight, now, expires_at, owner, inflight_ttl_ms)
    zremrangebyscore(inflight, now)
    return 0 unless zscore(inflight, owner)

    zadd(inflight, expires_at, owner)
    @sets[inflight][:expires_at] = now_ms + inflight_ttl_ms.to_i
    1
  end

  def claim_refresh_slots(mutex, inflight, balance, owner, ttl_ms, now)
    return 0 if (get(balance) || '0').to_i.positive?

    zremrangebyscore(inflight, now)
    return 0 if zcard(inflight).positive?

    set(mutex, owner, nx: true, px: ttl_ms.to_i) ? 1 : 0
  end

  def replace_slots_if_empty(key, mutex_key, count, owner, ttl_ms)
    return -1 unless get(mutex_key) == owner

    n = (get(key) || '0').to_i
    return n if n.positive?

    count = 0 if count.to_i.negative?
    set(key, count.to_i, px: ttl_ms)
    count.to_i
  end

  def register_wait(key, now, expires_at, owner, ttl_ms)
    zremrangebyscore(key, now)
    zadd(key, expires_at, owner)
    @sets[key][:expires_at] = now_ms + ttl_ms.to_i
    1
  end

  def waiting(key, now)
    zremrangebyscore(key, now)
    zcard(key)
  end

  def acquire_room_for_sync(room_key, wait_key, owner, ttl_ms, now)
    zremrangebyscore(wait_key, now)
    return 0 if zcard(wait_key).positive?

    set(room_key, owner, nx: true, px: ttl_ms) ? 1 : 0
  end

  # Ruby stand-ins for SyncAccount's Lua scripts: same arguments, same return codes.
  def sync_acquire(slots, owners, now, expires_at, limit, login, owner)
    sync_purge(slots, owners, now)
    return 0 if hget(owners, login)
    return -1 if zcard(slots) >= limit.to_i

    hset(owners, login, owner)
    zadd(slots, expires_at, login)
    1
  end

  def sync_extend(slots, owners, now, expires_at, login, owner)
    sync_purge(slots, owners, now)
    return 0 unless hget(owners, login) == owner

    zadd(slots, expires_at, login)
    1
  end

  def sync_release(slots, owners, login, owner)
    return 0 unless hget(owners, login) == owner

    hdel(owners, login)
    zrem(slots, login)
    1
  end

  def sync_purge(slots, owners, now)
    zrangebyscore_upto(slots, now).each { |login| hdel(owners, login) }
    zremrangebyscore(slots, now)
  end

  def zrangebyscore_upto(key, now)
    purge_set(key)
    (@sets.dig(key, :members) || {}).select { |_member, score| score <= now.to_i }.keys
  end

  def hget(key, field)
    @hashes.dig(key, field)
  end

  def hset(key, field, value)
    (@hashes[key] ||= {})[field] = value
    1
  end

  def hdel(key, field)
    @hashes[key]&.delete(field)
    1
  end

  def zadd(key, score, member)
    bucket = (@sets[key] ||= { members: {}, expires_at: nil })
    bucket[:members][member] = score.to_i
    1
  end

  def zrem(key, member)
    return 0 unless @sets[key]&.dig(:members)&.delete(member)

    1
  end

  def zscore(key, member)
    purge_set(key)
    @sets[key]&.dig(:members, member)
  end

  def zcard(key)
    purge_set(key)
    @sets[key]&.dig(:members)&.size.to_i
  end

  def zremrangebyscore(key, now)
    purge_set(key)
    return unless @sets[key]

    @sets[key][:members].delete_if { |_member, score| score <= now.to_i }
  end

  def purge_string(key)
    entry = @strings[key]
    return unless entry
    return if entry[:expires_at].nil? || entry[:expires_at] > now_ms

    @strings.delete(key)
  end

  def purge_set(key)
    entry = @sets[key]
    return unless entry
    return if entry[:expires_at].nil? || entry[:expires_at] > now_ms

    @sets.delete(key)
  end
end
