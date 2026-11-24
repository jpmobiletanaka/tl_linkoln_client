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
end
