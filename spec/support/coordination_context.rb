# frozen_string_literal: true

# Shared setup for the Coordination specs: a fake Redis assigned to the
# client for the duration of each example, plus common login/owner values.
RSpec.shared_context 'with fake redis' do
  let(:redis) { FakeRedis.new }
  let(:system_id) { 'system-1' }
  let(:user_id) { 'user-1' }
  let(:room_code) { 'ROOM-A' }
  let(:owner) { 'revenue:send:1' }

  before { TlLinkolnClient::Coordination.redis = redis }

  after { TlLinkolnClient::Coordination.redis = nil }
end
