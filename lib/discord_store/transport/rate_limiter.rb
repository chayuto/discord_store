# frozen_string_literal: true

require_relative "quota"
require_relative "bucket"

module DiscordStore
  module Transport
    # Learns Discord's rate-limit topology at runtime and holds requests back to
    # fit inside it.
    #
    # Two layers, because Discord enforces two:
    #
    #   Quota   — the token-wide budget, roughly 50 requests/second across
    #             everything. One instance per process.
    #   Bucket  — a per-route, per-major-parameter window (five messages per five
    #             seconds in a given channel, and so on). Learned from response
    #             headers; several route keys may resolve to one shared bucket.
    #
    # A request must satisfy both before it goes out, and both are updated from
    # every response, including the failures.
    class RateLimiter
      # Response headers Discord uses to describe the limit that applied.
      HEADER_BUCKET = "x-ratelimit-bucket"
      HEADER_LIMIT = "x-ratelimit-limit"
      HEADER_REMAINING = "x-ratelimit-remaining"
      HEADER_RESET_AFTER = "x-ratelimit-reset-after"
      HEADER_SCOPE = "x-ratelimit-scope"
      HEADER_GLOBAL = "x-ratelimit-global"
      HEADER_RETRY_AFTER = "retry-after"

      attr_reader :quota

      # @param rate [Numeric] global permits per second
      # @param clock [#call]
      def initialize(rate:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @quota = Quota.new(rate: rate, clock: clock)
        @clock = clock
        @route_buckets = {}
        @shared_buckets = {}
        @registry_mutex = Mutex.new
      end

      # Acquires both layers of permission for +route_key+.
      #
      # @param route_key [String] method plus path with major parameters resolved,
      #   e.g. "POST /channels/123/messages"
      # @param timeout [Numeric, nil]
      # @return [void]
      def acquire(route_key, timeout: nil)
        started = @clock.call
        @quota.acquire(timeout: timeout)

        remaining = timeout && [timeout - (@clock.call - started), 0.0].max
        bucket_for(route_key).acquire(timeout: remaining)
      end

      # Folds a response's rate-limit headers back into local state.
      #
      # @param route_key [String]
      # @param headers [Hash] downcased header name => value
      # @return [void]
      def observe(route_key, headers)
        headers = normalize(headers)
        bucket = bucket_for(route_key)

        if (hash_key = headers[HEADER_BUCKET])
          bucket = adopt_shared_bucket(route_key, bucket, hash_key)
        end

        bucket.update(
          limit: headers[HEADER_LIMIT],
          remaining: headers[HEADER_REMAINING],
          reset_after: headers[HEADER_RESET_AFTER]
        )
      end

      # Applies the server-mandated backoff from a 429.
      #
      # @param route_key [String]
      # @param headers [Hash]
      # @return [Float] seconds the caller should wait before retrying
      def penalize(route_key, headers)
        headers = normalize(headers)
        retry_after = (headers[HEADER_RESET_AFTER] || headers[HEADER_RETRY_AFTER]).to_f
        retry_after = 1.0 if retry_after <= 0

        if global?(headers)
          # The token is over budget everywhere; holding back one bucket would
          # accomplish nothing.
          @quota.penalize(retry_after)
        else
          bucket_for(route_key).penalize(retry_after)
        end

        retry_after
      end

      # @param headers [Hash]
      # @return [Boolean] whether a 429 applied to the whole token
      def global?(headers)
        headers = normalize(headers)
        headers[HEADER_GLOBAL].to_s == "true" || headers[HEADER_SCOPE].to_s == "global"
      end

      # @return [Hash] every known bucket, for instrumentation and tests
      def inspect_buckets
        @registry_mutex.synchronize { @route_buckets.transform_values(&:state) }
      end

      private

      def bucket_for(route_key)
        @registry_mutex.synchronize do
          @route_buckets[route_key] ||= Bucket.new(clock: @clock)
        end
      end

      # Discord groups routes into shared buckets. Once we learn that this route
      # belongs to a bucket we have already seen, we point the route at the
      # existing bucket object so both routes draw down one window instead of
      # each keeping a private, over-optimistic count.
      def adopt_shared_bucket(route_key, bucket, hash_key)
        @registry_mutex.synchronize do
          existing = @shared_buckets[hash_key]

          if existing.nil?
            bucket.hash_key = hash_key
            @shared_buckets[hash_key] = bucket
            bucket
          elsif existing.equal?(bucket)
            bucket
          else
            @route_buckets[route_key] = existing
            existing
          end
        end
      end

      def normalize(headers)
        return {} if headers.nil?

        headers.each_with_object({}) do |(key, value), out|
          out[key.to_s.downcase] = value.is_a?(Array) ? value.first : value
        end
      end
    end
  end
end
