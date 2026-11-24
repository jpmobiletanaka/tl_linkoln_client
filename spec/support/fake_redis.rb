# frozen_string_literal: true

# In-memory stand-in for the Redis commands Coordination sends.
# Expiry is driven by #now_ms so specs do not sleep.
class FakeRedis
  attr_accessor :now_ms

  def initialize
    @strings = {}
    @sets = {}
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
    when coordination::HotelLimit::ENTER
      enter_hotel(keys[0], argv[0], argv[1], argv[2], argv[3])
    when coordination::HotelLimit::EXTEND
      extend_hotel(keys[0], argv[0], argv[1], argv[2])
    when coordination::HotelLimit::LEAVE
      zrem(keys[0], argv[0])
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

  def enter_hotel(key, now, expires_at, limit, member)
    zremrangebyscore(key, now)
    if zscore(key, member)
      zadd(key, expires_at, member)
      return 1
    end
    return 0 if zcard(key) >= limit.to_i

    zadd(key, expires_at, member)
    1
  end

  def extend_hotel(key, now, expires_at, member)
    zremrangebyscore(key, now)
    return 0 unless zscore(key, member)

    zadd(key, expires_at, member)
    1
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
