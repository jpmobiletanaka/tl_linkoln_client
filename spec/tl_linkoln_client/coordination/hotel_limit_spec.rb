# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TlLinkolnClient::Coordination::HotelLimit do
  include_context 'with fake redis'

  it 'caps distinct logins and counts the same login once' do
    expect(described_class.enter_send(system_id: system_id, user_id: user_id, limit: 1)).to eq(true)
    expect(described_class.enter_send(system_id: system_id, user_id: user_id, limit: 1)).to eq(true)
    expect(described_class.enter_send(system_id: 'other', user_id: user_id, limit: 1)).to eq(false)

    expect(described_class.leave_send(system_id: system_id, user_id: user_id)).to eq(true)
    expect(described_class.enter_send(system_id: 'other', user_id: user_id, limit: 1)).to eq(true)
  end

  it 'does not let an expired membership occupy a slot' do
    entered_at = described_class.now_ms
    allow(described_class).to receive(:now_ms).and_return(entered_at)
    described_class.enter_send(system_id: system_id, user_id: user_id, limit: 1, ttl_ms: 1_000)
    allow(described_class).to receive(:now_ms).and_return(entered_at + 1_001)

    expect(described_class.enter_send(system_id: 'other', user_id: user_id, limit: 1)).to eq(true)
  end

  it 'extends only a live membership' do
    expect(described_class.extend_send(system_id: system_id, user_id: user_id)).to eq(false)

    described_class.enter_send(system_id: system_id, user_id: user_id, limit: 1)

    expect(described_class.extend_send(system_id: system_id, user_id: user_id)).to eq(true)
  end

  it 'keeps send and sync counters independent' do
    expect(described_class.enter_send(system_id: system_id, user_id: user_id, limit: 1)).to eq(true)
    expect(described_class.enter_sync(system_id: 'other', user_id: user_id, limit: 1)).to eq(true)
  end
end
