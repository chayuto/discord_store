# frozen_string_literal: true

module DiscordStore
  module Transport
    # One Discord rate-limit bucket.
    #
    # Discord does not publish its per-route limits; it reports them, per
    # response, in the X-RateLimit-* headers, and groups routes into opaque
    # buckets identified by X-RateLimit-Bucket. Several routes can share one
    # bucket, so the limiter learns the mapping at runtime rather than assuming
    # a table of constants that will be wrong by next quarter.
    #
    # The limit that dominates this library is five messages per five seconds
    # per channel. That is the number that caps a naive Discord-backed store,
    # and the only real answer to it is to write to more than one channel —
    # which is why {ChannelShard} exists.
    class Bucket
      UNKNOWN = nil

      attr_reader :hash_key

      def initialize(hash_key: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @hash_key = hash_key
        @clock = clock
        @limit = UNKNOWN
        @remaining = UNKNOWN
        @reset_at = nil
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      # Blocks until this bucket has room, then claims a slot optimistically.
      # The claim is provisional: {#update} reconciles it against whatever the
      # server actually reports, and the server's number always wins.
      #
      # @param timeout [Numeric, nil]
      # @return [void]
      # @raise [QuotaTimeoutError]
      def acquire(timeout: nil)
        deadline = timeout && (@clock.call + timeout)

        @mutex.synchronize do
          loop do
            expire_window

            # Nothing learned yet: let one request through so there is something
            # to learn from.
            if @remaining == UNKNOWN
              @remaining = UNKNOWN
              return
            end

            if @remaining.positive?
              @remaining -= 1
              return
            end

            wait = [@reset_at.to_f - @clock.call, 0.0].max

            if deadline
              remaining_time = deadline - @clock.call
              if remaining_time <= 0
                raise QuotaTimeoutError,
                      "waited #{timeout}s for rate-limit bucket #{@hash_key || "(unlearned)"} to reset"
              end

              wait = [wait, remaining_time].min
            end

            # A zero wait with no deadline would spin; give the scheduler a tick.
            @condition.wait(@mutex, wait.positive? ? wait : 0.01)
          end
        end
      end

      # Reconciles local state with the headers on a response.
      #
      # @param limit [Integer, nil]
      # @param remaining [Integer, nil]
      # @param reset_after [Float, nil] seconds until the window resets
      # @return [void]
      def update(limit: nil, remaining: nil, reset_after: nil)
        @mutex.synchronize do
          @limit = Integer(limit) if limit
          @reset_at = @clock.call + Float(reset_after) if reset_after

          if remaining
            reported = Integer(remaining)
            # Requests we have already let through but whose responses have not
            # come back yet are not reflected in the server's count, so take the
            # pessimistic view.
            @remaining = @remaining == UNKNOWN ? reported : [@remaining, reported].min
          end

          @condition.broadcast
        end
      end

      # Records the bucket hash the server assigned to this route.
      #
      # @param hash_key [String]
      # @return [void]
      def hash_key=(hash_key)
        @mutex.synchronize { @hash_key = hash_key }
      end

      # Closes the bucket for +seconds+ after a 429.
      #
      # @param seconds [Numeric]
      # @return [void]
      def penalize(seconds)
        @mutex.synchronize do
          @remaining = 0
          @reset_at = @clock.call + seconds.to_f
        end
      end

      # @return [Hash] a snapshot, for instrumentation and tests
      def state
        @mutex.synchronize do
          {
            hash_key: @hash_key,
            limit: @limit,
            remaining: @remaining,
            reset_in: @reset_at ? [@reset_at - @clock.call, 0.0].max : nil
          }
        end
      end

      private

      # Assumes the mutex is held.
      def expire_window
        return unless @reset_at && @clock.call >= @reset_at

        @remaining = @limit == UNKNOWN ? UNKNOWN : @limit
        @reset_at = nil
      end
    end
  end
end
