# frozen_string_literal: true

module TlLinkolnClient
  class Coordination
    # Keeps a lock or a reservation alive while its owner is still working.
    #
    # Two ways to renew:
    # - a background thread calls the renewal block every `interval` seconds;
    # - #renew! can be called synchronously by the owner right before it acts on the key
    #   (e.g. before a write or before a request to TL). This is the check that matters: after a long pause
    #   the background thread may not have run yet.
    #
    # The lease counts as lost when:
    # - a renewal is refused (the key no longer belongs to the owner),
    # - a renewal raises,
    # - `max_duration` has passed. This is checked against the clock on every call to #lost? and #renew!,
    #   so it does not wait for the background thread.
    #
    # `max_duration` limits how long the owner keeps the key alive. It does not stop work that is already
    # running: the owner must check #renew! before each step that depends on the key.
    class Lease
      DEFAULT_INTERVAL = 15        # seconds between background renewals
      DEFAULT_MAX_DURATION = 300   # seconds after which renewals stop and the lease counts as lost
      MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      class << self
        # Starts renewing right away. The block must return true while the key still belongs to the owner.
        def start(interval: DEFAULT_INTERVAL, max_duration: DEFAULT_MAX_DURATION, clock: MONOTONIC_CLOCK, &renew)
          new(interval: interval, max_duration: max_duration, clock: clock, &renew).start
        end
      end

      def initialize(interval: DEFAULT_INTERVAL, max_duration: DEFAULT_MAX_DURATION, clock: MONOTONIC_CLOCK, &renew)
        raise ArgumentError, 'renew block is required' unless renew

        @interval = interval
        @clock = clock
        @deadline = clock.call + max_duration
        @renew = renew
        @lost = false
        @mutex = Mutex.new        # guards @lost
        @renew_mutex = Mutex.new  # serializes renewals from the thread and from the owner
        @stop_mutex = Mutex.new
        @stop_cv = ConditionVariable.new
        @stopped = false
        @thread = nil
      end

      # True when the lease is lost, including when the deadline has passed. Does not touch Redis.
      def lost?
        @mutex.synchronize do
          @lost ||= past_deadline?
          @lost
        end
      end

      # Renews the key now. Returns false and marks the lease lost when it is lost already,
      # past its deadline, refused by the block, or the block raises.
      def renew!
        @renew_mutex.synchronize do
          return false if lost?
          return true if @renew.call

          mark_lost!
          false
        end
      rescue StandardError
        mark_lost!
        false
      end

      def start
        @thread ||= Thread.new do
          loop do
            break if wait_for_interval
            break unless renew!
          end
        end
        self
      end

      # Stops background renewals without waiting for the next interval. Safe to call more than once.
      # Does not release the key: the owner does that itself.
      def stop
        @stop_mutex.synchronize do
          @stopped = true
          @stop_cv.broadcast
        end
        @thread&.join
        self
      end

      private

      def past_deadline?
        @clock.call >= @deadline
      end

      # Sleeps for one interval. Returns true when #stop was called meanwhile.
      def wait_for_interval
        @stop_mutex.synchronize do
          @stop_cv.wait(@stop_mutex, @interval) unless @stopped
          @stopped
        end
      end

      def mark_lost!
        @mutex.synchronize { @lost = true }
        false
      end
    end
  end
end
