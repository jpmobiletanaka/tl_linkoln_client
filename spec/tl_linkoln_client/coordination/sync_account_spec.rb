# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TlLinkolnClient::Coordination::SyncAccount do
  include_context 'with fake redis'

  it 'raises when the client was not assigned' do
    TlLinkolnClient::Coordination.redis = nil

    expect { described_class.acquire(system_id: system_id, user_id: user_id, owner: owner) }
      .to raise_error(TlLinkolnClient::Coordination::RedisNotConfigured)
  end

  it 'is per login' do
    expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: owner)).to eq(true)
    expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)
    expect(described_class.acquire(system_id: 'other', user_id: user_id, owner: 'metro')).to eq(true)
  end

  it 'releases only for the owner' do
    described_class.acquire(system_id: system_id, user_id: user_id, owner: owner)

    expect(described_class.release(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)
    expect(described_class.release(system_id: system_id, user_id: user_id, owner: owner)).to eq(true)
  end

  it 'extends only for its owner and never re-creates an expired lock' do
    expect(described_class.extend(system_id: system_id, user_id: user_id, owner: owner)).to eq(false)

    described_class.acquire(system_id: system_id, user_id: user_id, owner: owner)
    expect(described_class.extend(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)

    redis.now_ms += described_class::TTL_MS / 2
    expect(described_class.extend(system_id: system_id, user_id: user_id, owner: owner)).to eq(true)

    redis.now_ms += described_class::TTL_MS / 2 + 1 # past original ttl, still inside extended ttl
    expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)

    redis.now_ms += described_class::TTL_MS / 2 # extended ttl expired too
    expect(described_class.extend(system_id: system_id, user_id: user_id, owner: owner)).to eq(false)
    expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(true)
  end

  it 'requires a positive ttl' do
    expect { described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, ttl_ms: 0) }
      .to raise_error(ArgumentError, 'ttl_ms must be positive')

    described_class.acquire(system_id: system_id, user_id: user_id, owner: owner)
    expect { described_class.extend(system_id: system_id, user_id: user_id, owner: owner, ttl_ms: -1) }
      .to raise_error(ArgumentError, 'ttl_ms must be positive')
  end

  it 'keeps raw credentials out of the key' do
    described_class.acquire(system_id: system_id, user_id: user_id, owner: owner)

    expect(redis.string_keys.join).not_to include(system_id)
    expect(redis.string_keys.join).not_to include(user_id)
  end

  describe '.with_lock' do
    it 'holds the login while the block runs and yields a guard' do
      yielded = nil
      result = described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner) do |guard|
        yielded = guard
        expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)
        :done
      end

      expect(result).to eq(:done)
      expect(yielded).to be_a(described_class::Guard)
      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(true)
    end

    it 'raises AlreadyLocked when another sync holds the login and does not run the block' do
      described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')
      ran = false

      expect do
        described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner) { ran = true }
      end.to raise_error(described_class::AlreadyLocked)
      expect(ran).to eq(false)
    end

    it 'releases the lock when the block raises' do
      expect do
        described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner) { raise 'boom' }
      end.to raise_error(RuntimeError, 'boom')

      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(true)
    end

    it 'assert_locked! extends the lock past its initial ttl without any background thread' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner) do |guard|
        redis.now_ms += described_class::TTL_MS / 2
        expect { guard.assert_locked! }.not_to raise_error

        redis.now_ms += described_class::TTL_MS / 2 + 1 # past initial ttl, still inside extended ttl
        expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)
        expect(guard.lost?).to eq(false)
      end
    end

    it 'assert_locked! raises Lost when another owner took the lock over after expiry' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner) do |guard|
        redis.now_ms += described_class::TTL_MS + 1
        described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')

        expect { guard.assert_locked! }.to raise_error(described_class::Lost)
        expect(guard.lost?).to eq(true)
      end
    end

    it 'has no total duration limit: a sync that keeps reaching its checks keeps the lock' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner) do |guard|
        20.times do
          redis.now_ms += described_class::TTL_MS - 1
          expect { guard.assert_locked! }.not_to raise_error
        end
        expect(guard.lost?).to eq(false)
      end
    end

    it 'does not release a lock that was taken over' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner) do
        redis.now_ms += described_class::TTL_MS + 1
        described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro')
      end

      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'third')).to eq(false)
    end
  end
end
