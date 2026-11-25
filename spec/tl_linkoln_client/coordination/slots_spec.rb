# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TlLinkolnClient::Coordination::Slots do
  include_context 'with fake redis'

  def claim(by = owner)
    described_class.claim_refresh(system_id: system_id, user_id: user_id, owner: by)
  end

  def replace(count, owner: self.owner, **options)
    described_class.replace_if_empty(
      system_id: system_id, user_id: user_id, count: count, owner: owner, **options
    )
  end

  def take(by = owner)
    described_class.take(system_id: system_id, user_id: user_id, owner: by)
  end

  def release_reservation(by = owner)
    described_class.release_reservation(system_id: system_id, user_id: user_id, owner: by)
  end

  def read
    described_class.read(system_id: system_id, user_id: user_id)
  end

  it 'consumes a stored balance and stops at zero' do
    expect(read).to be_nil
    expect(take).to eq(false)

    claim
    expect(replace(2)).to eq(2)
    expect(take).to eq(true)
    expect(read).to eq(1)
    expect(take).to eq(true)
    expect(take).to eq(false)
  end

  it 'does not overwrite a balance that is still positive' do
    claim
    replace(2)
    take

    expect(replace(9)).to eq(1)
  end

  it 'does not write when the caller does not own the refresh mutex' do
    expect(replace(5)).to be_nil
    expect(read).to be_nil

    described_class.claim_refresh(system_id: system_id, user_id: user_id, owner: 'other')
    expect(replace(5)).to be_nil
    expect(read).to be_nil
  end

  it 'does not write a stale answer after the mutex expired and was taken over' do
    claim
    redis.now_ms += described_class::REFRESH_TTL_MS + 1
    expect(claim('other')).to eq(true)

    expect(replace(5)).to be_nil
    expect(read).to be_nil
  end

  it 'expires the balance after the ttl' do
    claim
    replace(3)
    expect(read).to eq(3)

    redis.now_ms += described_class::BALANCE_TTL_MS - 1
    expect(read).to eq(3)

    redis.now_ms += 2
    expect(read).to be_nil
    expect(take).to eq(false)
  end

  it 'accepts a custom balance ttl' do
    claim
    replace(3, ttl_ms: 1_000)

    redis.now_ms += 1_001
    expect(read).to be_nil
  end

  it 'does not extend the balance ttl when slots are consumed' do
    claim
    replace(3)
    redis.now_ms += described_class::BALANCE_TTL_MS - 1
    take

    redis.now_ms += 2
    expect(read).to be_nil
  end

  it 'requires an owner' do
    expect { replace(1, owner: '') }.to raise_error(ArgumentError, 'owner is blank')
    expect { take('') }.to raise_error(ArgumentError, 'owner is blank')
  end

  it 'requires a positive balance ttl' do
    expect { replace(1, ttl_ms: 0) }.to raise_error(ArgumentError, 'ttl_ms must be positive')
    expect { replace(1, ttl_ms: -5) }.to raise_error(ArgumentError, 'ttl_ms must be positive')
  end

  it 'holds the refresh mutex for one owner' do
    expect(claim).to eq(true)
    expect(claim('other')).to eq(false)
    expect(described_class.release_refresh(system_id: system_id, user_id: user_id, owner: 'other')).to eq(false)
    expect(described_class.release_refresh(system_id: system_id, user_id: user_id, owner: owner)).to eq(true)
    expect(claim('other')).to eq(true)
  end

  it 'does not refresh while the balance is positive, even with nothing in flight' do
    claim
    replace(2)
    described_class.release_refresh(system_id: system_id, user_id: user_id, owner: owner)

    expect(claim('other')).to eq(false)
    expect(read).to eq(2)
  end

  it 'refuses a refresh that starts right after a refill, and the slot is still taken once' do
    claim
    replace(1)
    described_class.release_refresh(system_id: system_id, user_id: user_id, owner: owner)

    # Worker A has an empty view, but the balance was refilled before it claimed.
    expect(claim('a')).to eq(false)
    expect(take('b')).to eq(true)  # B consumes the slot and is in flight
    expect(claim('a')).to eq(false) # balance is 0, but B is in flight
    expect(take('a')).to eq(false)

    release_reservation('b')
    expect(claim('a')).to eq(true)
  end

  def extend_reservation(by = owner)
    described_class.extend_reservation(system_id: system_id, user_id: user_id, owner: by)
  end

  describe 'keeping a reservation alive' do
    before do
      claim
      replace(1)
      described_class.release_refresh(system_id: system_id, user_id: user_id, owner: owner)
    end

    it 'outlives its original ttl while it is extended' do
      take
      redis.now_ms += described_class::INFLIGHT_TTL_MS / 2
      expect(extend_reservation).to eq(true)

      redis.now_ms += described_class::INFLIGHT_TTL_MS / 2 + 1 # the original ttl has passed
      expect(claim('other')).to eq(false)

      redis.now_ms += described_class::INFLIGHT_TTL_MS / 2 # the extended ttl has passed too
      expect(claim('other')).to eq(true)
    end

    it 'does not re-create a reservation that already expired' do
      take
      redis.now_ms += described_class::INFLIGHT_TTL_MS + 1

      expect(extend_reservation).to eq(false)
      expect(claim('other')).to eq(true)
    end

    it 'does not extend a reservation of another owner' do
      take
      expect(extend_reservation('other')).to eq(false)
    end

    it 'does not re-create a reservation after it was released' do
      take
      release_reservation

      expect(extend_reservation).to eq(false)
      expect(claim('other')).to eq(true)
    end
  end

  describe 'in-flight reservations' do
    before do
      claim
      replace(1)
      described_class.release_refresh(system_id: system_id, user_id: user_id, owner: owner)
    end

    it 'does not refresh while a send holds a reservation' do
      expect(take).to eq(true)

      expect(claim('other')).to eq(false)

      release_reservation
      expect(claim('other')).to eq(true)
    end

    it 'lets a refresh through when the reservation is released' do
      take
      release_reservation

      expect(claim('other')).to eq(true)
    end

    it 'does not reserve anything when the balance is empty' do
      take
      expect(take('other')).to eq(false)

      expect(claim('other')).to eq(false) # the first reservation is still in flight
      release_reservation
      expect(claim('other')).to eq(true)
    end

    it 'releases only the reservation of its own owner' do
      take
      release_reservation('other')

      expect(claim('other')).to eq(false)
    end

    it 'stops blocking refresh after the in-flight ttl when the owner never releases' do
      take
      redis.now_ms += described_class::INFLIGHT_TTL_MS + 1

      expect(claim('other')).to eq(true)
    end

    it 'release is safe to call twice' do
      take
      expect(release_reservation).to eq(true)
      expect(release_reservation).to eq(false)
    end
  end
end
