# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe TlLinkolnClient::Coordination::Lease do
  let(:now) { [0.0] }
  let(:clock) { -> { now.first } }
  let(:renewals) { [] }

  def make_lease(&renew)
    described_class.new(interval: 10, max_duration: 100, clock: clock, &renew)
  end

  it 'stays alive while renewals succeed' do
    lease = make_lease { renewals << :ok; true }

    expect(lease.renew!).to eq(true)
    expect(lease.lost?).to eq(false)
  end

  it 'is lost as soon as a renewal is refused, and does not renew again' do
    lease = make_lease { renewals << :refused; false }

    expect(lease.renew!).to eq(false)
    expect(lease.lost?).to eq(true)
    expect(lease.renew!).to eq(false)
    expect(renewals).to eq([:refused])
  end

  it 'is lost when a renewal raises' do
    lease = make_lease { raise 'connection reset' }

    expect(lease.renew!).to eq(false)
    expect(lease.lost?).to eq(true)
  end

  it 'is lost after max_duration and stops renewing' do
    lease = make_lease { renewals << :ok; true }
    now[0] = 100.0

    expect(lease.renew!).to eq(false)
    expect(renewals).to be_empty
    expect(lease.lost?).to eq(true)
  end

  it 'stops its background thread without waiting for the next interval' do
    lease = make_lease { renewals << :ok; true }

    expect { Timeout.timeout(2) { lease.start.stop } }.not_to raise_error
    expect(renewals).to be_empty
  end

  it 'is lost as soon as the deadline passes, without waiting for a background renewal' do
    lease = make_lease { renewals << :ok; true }
    expect(lease.lost?).to eq(false)

    now[0] = 100.0

    expect(lease.lost?).to eq(true)
  end

  it 'renews synchronously when asked, without a background thread' do
    lease = make_lease { renewals << :ok; true }

    expect(lease.renew!).to eq(true)
    expect(renewals).to eq([:ok])
  end

  it 'does not renew synchronously after the deadline, even if the block would accept it' do
    lease = make_lease { renewals << :ok; true }
    now[0] = 100.0

    expect(lease.renew!).to eq(false)
    expect(renewals).to be_empty
  end

  it 'stays lost once lost, even if a later renewal would succeed' do
    responses = [false, true]
    lease = make_lease { responses.shift }

    expect(lease.renew!).to eq(false)
    expect(lease.renew!).to eq(false)
    expect(lease.lost?).to eq(true)
  end

  it 'requires a renew block' do
    expect { described_class.new(interval: 10, max_duration: 100, clock: clock) }
      .to raise_error(ArgumentError, 'renew block is required')
  end
end
