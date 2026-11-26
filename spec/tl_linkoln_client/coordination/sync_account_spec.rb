# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TlLinkolnClient::Coordination::SyncAccount do
  include_context 'with fake redis'

  let(:limit) { 10 }

  before do
    # The scripts take `now` from Ruby, so point it at the fake clock to be able to move time.
    allow(described_class).to receive(:now_ms) { redis.now_ms }
  end

  it 'raises when the client was not assigned' do
    TlLinkolnClient::Coordination.redis = nil

    expect { described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit) }
      .to raise_error(TlLinkolnClient::Coordination::RedisNotConfigured)
  end

  describe '.acquire' do
    it 'takes the login and a slot' do
      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit)).to eq(:ok)
    end

    it 'reports :already for a login held by another owner, and lets other logins through' do
      described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit)

      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit))
        .to eq(:already)
      expect(described_class.acquire(system_id: 'other', user_id: user_id, owner: 'metro', limit: limit))
        .to eq(:ok)
    end

    it 'reports :full when all slots are taken by other logins' do
      described_class.acquire(system_id: 'a', user_id: user_id, owner: 'o1', limit: 2)
      described_class.acquire(system_id: 'b', user_id: user_id, owner: 'o2', limit: 2)

      expect(described_class.acquire(system_id: 'c', user_id: user_id, owner: 'o3', limit: 2)).to eq(:full)
    end

    it 'allows MAX_PARALLEL logins at once when no limit is given' do
      described_class::MAX_PARALLEL.times do |i|
        expect(described_class.acquire(system_id: "login-#{i}", user_id: user_id, owner: "o#{i}")).to eq(:ok)
      end

      expect(described_class.acquire(system_id: 'one-more', user_id: user_id, owner: 'late')).to eq(:full)
    end

    it 'checks the login before the capacity: a held login is :already even when full' do
      described_class.acquire(system_id: 'a', user_id: user_id, owner: 'o1', limit: 1)

      expect(described_class.acquire(system_id: 'a', user_id: user_id, owner: 'o2', limit: 1)).to eq(:already)
    end

    it 'frees the slot when the login is released' do
      described_class.acquire(system_id: 'a', user_id: user_id, owner: 'o1', limit: 1)
      expect(described_class.acquire(system_id: 'b', user_id: user_id, owner: 'o2', limit: 1)).to eq(:full)

      described_class.release(system_id: 'a', user_id: user_id, owner: 'o1')

      expect(described_class.acquire(system_id: 'b', user_id: user_id, owner: 'o2', limit: 1)).to eq(:ok)
    end

    it 'frees the slot when the hold expires' do
      described_class.acquire(system_id: 'a', user_id: user_id, owner: 'o1', limit: 1)

      redis.now_ms += described_class::TTL_MS + 1

      expect(described_class.acquire(system_id: 'b', user_id: user_id, owner: 'o2', limit: 1)).to eq(:ok)
    end

    it 'requires a positive ttl and a positive limit' do
      expect { described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit, ttl_ms: 0) }
        .to raise_error(ArgumentError, 'ttl_ms must be positive')
      expect { described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: 0) }
        .to raise_error(ArgumentError, 'limit must be positive')
    end
  end

  describe '.extend and .release' do
    it 'extends only for its owner and never re-creates an expired hold' do
      described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit)
      expect(described_class.extend(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)

      redis.now_ms += described_class::TTL_MS / 2
      expect(described_class.extend(system_id: system_id, user_id: user_id, owner: owner)).to eq(true)

      redis.now_ms += described_class::TTL_MS / 2 + 1 # past the original ttl, inside the extended one
      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit))
        .to eq(:already)

      redis.now_ms += described_class::TTL_MS / 2 # the extended ttl expired too
      expect(described_class.extend(system_id: system_id, user_id: user_id, owner: owner)).to eq(false)
      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit))
        .to eq(:ok)
    end

    it 'releases only for the owner' do
      described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit)

      expect(described_class.release(system_id: system_id, user_id: user_id, owner: 'metro')).to eq(false)
      expect(described_class.release(system_id: system_id, user_id: user_id, owner: owner)).to eq(true)
    end

    it 'does not let an expired owner release a hold taken over by another owner' do
      described_class.acquire(system_id: system_id, user_id: user_id, owner: owner, limit: limit)
      redis.now_ms += described_class::TTL_MS + 1
      described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit)

      expect(described_class.release(system_id: system_id, user_id: user_id, owner: owner)).to eq(false)
      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'third', limit: limit))
        .to eq(:already)
    end
  end

  describe '.with_lock' do
    it 'holds the login and a slot while the block runs and yields a guard' do
      yielded = nil
      result = described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner, limit: limit) do |guard|
        yielded = guard
        expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit))
          .to eq(:already)
        :done
      end

      expect(result).to eq(:done)
      expect(yielded).to be_a(described_class::Guard)
      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit))
        .to eq(:ok)
    end

    it 'raises AlreadyLocked when the login is held, without running the block' do
      described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit)
      ran = false

      expect do
        described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner, limit: limit) { ran = true }
      end.to raise_error(described_class::AlreadyLocked)
      expect(ran).to eq(false)
    end

    it 'raises NoFreeSlots without running the block and without leaving the login held' do
      described_class.acquire(system_id: 'x', user_id: user_id, owner: 'metro', limit: 1)
      ran = false

      expect do
        described_class.with_lock(system_id: 'a', user_id: user_id, owner: owner, limit: 1) { ran = true }
      end.to raise_error(described_class::NoFreeSlots)
      expect(ran).to eq(false)
      expect(described_class.acquire(system_id: 'a', user_id: user_id, owner: 'third', limit: 2)).to eq(:ok)
    end

    it 'releases the login and the slot when the block raises' do
      expect do
        described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner, limit: limit) { raise 'boom' }
      end.to raise_error(RuntimeError, 'boom')

      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: 1)).to eq(:ok)
    end

    it 'gives the slot back when the block ends' do
      described_class.with_lock(system_id: 'a', user_id: user_id, owner: owner, limit: 1) { nil }

      expect(described_class.acquire(system_id: 'b', user_id: user_id, owner: 'metro', limit: 1)).to eq(:ok)
    end

    it 'assert_locked! extends the hold past its initial ttl without any background thread' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner, limit: limit) do |guard|
        redis.now_ms += described_class::TTL_MS / 2
        expect { guard.assert_locked! }.not_to raise_error

        redis.now_ms += described_class::TTL_MS / 2 + 1 # past the initial ttl, inside the extended one
        expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit))
          .to eq(:already)
        expect(guard.lost?).to eq(false)
      end
    end

    it 'assert_locked! raises Lost when another owner took the hold over after expiry' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner, limit: limit) do |guard|
        redis.now_ms += described_class::TTL_MS + 1
        described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit)

        expect { guard.assert_locked! }.to raise_error(described_class::Lost)
        expect(guard.lost?).to eq(true)
      end
    end

    it 'has no total duration limit: a sync that keeps reaching its checks keeps the hold' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner, limit: limit) do |guard|
        20.times do
          redis.now_ms += described_class::TTL_MS - 1
          expect { guard.assert_locked! }.not_to raise_error
        end
        expect(guard.lost?).to eq(false)
      end
    end

    it 'does not release a hold that was taken over' do
      described_class.with_lock(system_id: system_id, user_id: user_id, owner: owner, limit: limit) do
        redis.now_ms += described_class::TTL_MS + 1
        described_class.acquire(system_id: system_id, user_id: user_id, owner: 'metro', limit: limit)
      end

      expect(described_class.acquire(system_id: system_id, user_id: user_id, owner: 'third', limit: limit))
        .to eq(:already)
    end
  end
end
