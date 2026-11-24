# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TlLinkolnClient::Coordination::RoomLock do
  include_context 'with fake redis'

  it 'lets one owner hold a room and keeps other rooms free' do
    expect(described_class.acquire(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner)).to eq(true)
    expect(described_class.acquire(system_id: system_id, user_id: user_id, room_code: room_code, owner: 'other')).to eq(false)
    expect(described_class.acquire(system_id: system_id, user_id: user_id, room_code: 'ROOM-B', owner: 'other')).to eq(true)
  end

  it 'releases and extends only for the owner' do
    described_class.acquire(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner)

    expect(described_class.extend(system_id: system_id, user_id: user_id, room_code: room_code, owner: 'other')).to eq(false)
    expect(described_class.extend(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner)).to eq(true)
    expect(described_class.release(system_id: system_id, user_id: user_id, room_code: room_code, owner: 'other')).to eq(false)
    expect(described_class.release(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner)).to eq(true)
    expect(described_class.acquire(system_id: system_id, user_id: user_id, room_code: room_code, owner: 'other')).to eq(true)
  end

  it 'drops an expired room lock' do
    described_class.acquire(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner, ttl_ms: 1_000)
    redis.now_ms += 1_001

    expect(described_class.acquire(system_id: system_id, user_id: user_id, room_code: room_code, owner: 'other')).to eq(true)
  end

  it 'keeps raw credentials out of the key' do
    described_class.acquire(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner)

    expect(redis.string_keys.join).not_to include(system_id)
    expect(redis.string_keys.join).not_to include(user_id)
    expect(redis.string_keys.join).to include(room_code)
  end

  it 'blocks a sync acquire while a send is waiting, then allows it after clear' do
    described_class.register_send_wait(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner)

    expect(described_class.send_waiting?(system_id: system_id, user_id: user_id, room_code: room_code)).to eq(true)
    expect(described_class.acquire_for_sync(system_id: system_id, user_id: user_id, room_code: room_code, owner: 'sync')).to eq(false)

    described_class.clear_send_wait(system_id: system_id, user_id: user_id, room_code: room_code, owner: owner)

    expect(described_class.send_waiting?(system_id: system_id, user_id: user_id, room_code: room_code)).to eq(false)
    expect(described_class.acquire_for_sync(system_id: system_id, user_id: user_id, room_code: room_code, owner: 'sync')).to eq(true)
  end

  it 'ignores an expired wait marker' do
    registered_at = described_class.now_ms
    allow(described_class).to receive(:now_ms).and_return(registered_at)
    described_class.register_send_wait(
      system_id: system_id, user_id: user_id, room_code: room_code, owner: owner, ttl_ms: 1_000
    )
    redis.now_ms = registered_at + 1_001
    allow(described_class).to receive(:now_ms).and_return(registered_at + 1_001)

    expect(described_class.send_waiting?(system_id: system_id, user_id: user_id, room_code: room_code)).to eq(false)
  end
end
