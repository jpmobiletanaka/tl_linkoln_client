# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TlLinkolnClient::Coordination do
  include_context 'with fake redis'

  describe '.login_id' do
    it 'is stable and hides the raw credentials' do
      first = described_class.login_id(system_id, user_id)
      second = described_class.login_id(system_id, user_id)

      expect(first).to eq(second)
      expect(first).not_to include(system_id)
      expect(first).not_to include(user_id)
    end

    it 'differs when the login differs' do
      expect(described_class.login_id(system_id, user_id)).not_to eq(described_class.login_id('system-1', 'user-2'))
      expect(described_class.login_id('ab', 'c')).not_to eq(described_class.login_id('a', 'bc'))
    end

    it 'rejects a blank login' do
      expect { described_class.login_id('', user_id) }.to raise_error(ArgumentError, 'system_id is blank')
      expect { described_class.login_id(system_id, nil) }.to raise_error(ArgumentError, 'user_id is blank')
    end
  end
end
