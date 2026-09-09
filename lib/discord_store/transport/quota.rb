# frozen_string_literal: true

module DiscordStore
  module Transport
    # A token bucket over the whole bot token's request budget.
    #
    # This is the piece that replaces ActiveRecord's connection pool.
    #
    # A conventional adapter checks out a socket, because sockets are the scarce
    # resource and the database will happily answer as fast as you can ask. Over
    # Discord's REST API the opposite holds: connections are effectively free
    # and *permission to ask* is what runs out, at roughly fifty requests per
    # second per token, globally, across every channel and every process sharing
    # that token.
    #
    # So the checkout primitive here is a semaphore over quota rather than over
    # connections, and +pool:+ in database.yml means nothing. The failure mode is
    # the same one Rails users know — a timeout under concurrency — which is why
    # {QuotaTimeoutError} is deliberately shaped like ConnectionTimeoutError. It
    # arrives for a different reason, and raising the pool size cannot fix it.
    #
    # Fiber-safe: Mutex and ConditionVariable both defer to the fiber scheduler
    # when one is installed, so a Falcon or async worker parks its fiber here
    # instead of blocking its thread.
    class Quota
      # @return [Float] permits per second
      attr_reader :rate

      # @param rate [Numeric] permits per second
      # @param burst [Numeric, nil] bucket capacity; defaults to one second of rate
      # @param clock [#call] returns a monotonic float, injectable for tests. It
      #   must advance: both the refill and the acquire deadline are measured
      #   against it, so a frozen clock waits forever by construction.
      def initialize(rate:, burst: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        raise ArgumentError, "rate must be positive" unless rate.to_f.positive?

        @rate = rate.to_f
        @capacity = (burst || rate).to_f
        @tokens = @capacity
        @clock = clock
        @last_refill = @clock.call
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      # Blocks until one permit is available, then consumes it.
      #
      # @param timeout [Numeric, nil] seconds to wait; nil waits forever
      # @return [void]
      # @raise [QuotaTimeoutError] if no permit became available in time
      def acquire(timeout: nil)
        deadline = timeout && (@clock.call + timeout)

        @mutex.synchronize do
          loop do
            refill

            if @tokens >= 1.0
              @tokens -= 1.0
              return
            end

            wait = (1.0 - @tokens) / @rate

            if deadline
              remaining = deadline - @clock.call
              raise QuotaTimeoutError, timeout_message(timeout) if remaining <= 0

              wait = [wait, remaining].min
            end

            @condition.wait(@mutex, wait)
          end
        end
      end

      # Runs the block having first acquired a permit.
      #
      # @return [Object] the block's value
      def with(timeout: nil)
        acquire(timeout: timeout)
        yield
      end

      # Hands a permit back, for a request that never actually left. Capped at
      # capacity so that returning more than we took cannot inflate the budget.
      #
      # @return [void]
      def release
        @mutex.synchronize do
          @tokens = [@tokens + 1.0, @capacity].min
          @condition.signal
        end
      end

      # Drains the bucket and refuses permits for +seconds+. Called when Discord
      # answers 429 with a global scope: the server has told us our estimate of
      # the budget was wrong, and its number wins.
      #
      # @param seconds [Numeric]
      # @return [void]
      def penalize(seconds)
        @mutex.synchronize do
          @tokens = 0.0
          # Rewinding the refill clock into the future makes the next refill a
          # no-op until the penalty has elapsed, without a separate timer.
          @last_refill = @clock.call + seconds.to_f
        end
      end

      # @return [Float] permits currently available, for tests and instrumentation
      def available
        @mutex.synchronize do
          refill
          @tokens
        end
      end

      private

      def refill
        now = @clock.call
        elapsed = now - @last_refill
        return if elapsed <= 0 # penalized, or the clock did not move

        @tokens = [@tokens + (elapsed * @rate), @capacity].min
        @last_refill = now
      end

      def timeout_message(timeout)
        "waited #{timeout}s for Discord request quota (#{@rate}/s) and never got it. " \
          "This is not a connection pool problem and a larger pool will not fix it: " \
          "the token's global request budget is exhausted. Shed load, batch writes, " \
          "or shard across more channels."
      end
    end
  end
end
