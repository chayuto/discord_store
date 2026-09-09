# frozen_string_literal: true

require "json"
require_relative "http"
require_relative "rate_limiter"

module DiscordStore
  module Transport
    # The Discord REST surface this library uses, and nothing else.
    #
    # Deliberately small. Every method here exists to read or write data that
    # this bot itself wrote. There is no message search, no member enumeration,
    # no history export, and there will not be: the difference between a storage
    # backend and a scraper is whether it can read other people's messages, and
    # that difference is enforced in {#assert_own_message!} rather than in a
    # paragraph of the README.
    class REST
      MESSAGE_PAGE_LIMIT = 100
      BULK_DELETE_LIMIT = 100

      # Discord refuses to bulk-delete messages older than two weeks. Past that
      # the only route is one request per message, which is why the default
      # delete policy is to tombstone instead.
      BULK_DELETE_MAX_AGE = 14 * 24 * 60 * 60

      RETRYABLE_STATUSES = [429, 500, 502, 503, 504, 599].freeze

      attr_reader :config, :rate_limiter

      # @param config [DiscordStore::Configuration]
      # @param http [#call] an HTTP backend; defaults to Net::HTTP
      # @param rate_limiter [RateLimiter, nil]
      def initialize(config:, http: nil, rate_limiter: nil)
        @config = config.validate!
        @http = http || NetHTTP.new(
          open_timeout: config.open_timeout,
          read_timeout: config.read_timeout,
          write_timeout: config.write_timeout
        )
        @rate_limiter = rate_limiter || RateLimiter.new(rate: config.global_rate_limit)
      end

      # --- Messages ----------------------------------------------------------

      # @param channel_id [String]
      # @param content [String, nil]
      # @param nonce [String, nil] Discord deduplicates on this within a short
      #   window, which turns an at-least-once retry into an at-most-once write
      # @param files [Array<Hash>] each {filename:, content:, content_type:}
      # @return [Hash] the created message
      def create_message(channel_id, content: nil, nonce: nil, files: [])
        payload = {}
        payload[:content] = content if content
        payload[:nonce] = nonce if nonce
        # Belt and braces: we are writing machine data, and a stray @everyone
        # inside a base64 envelope should never page a guild.
        payload[:allowed_mentions] = { parse: [] }

        if files.empty?
          request(:post, "/channels/#{channel_id}/messages",
                  json: payload,
                  route: "POST /channels/#{channel_id}/messages")
        else
          content_type, body = Multipart.encode(JSON.generate(payload), files)
          request(:post, "/channels/#{channel_id}/messages",
                  body: body,
                  content_type: content_type,
                  route: "POST /channels/#{channel_id}/messages")
        end
      end

      # In-place update. This is the primitive that makes UPDATE cheap: a bot may
      # edit its own messages indefinitely, so a mutable row does not have to be
      # rewritten as delete-then-insert.
      #
      # @return [Hash] the edited message
      def edit_message(channel_id, message_id, content:)
        request(:patch, "/channels/#{channel_id}/messages/#{message_id}",
                json: { content: content, allowed_mentions: { parse: [] } },
                route: "PATCH /channels/#{channel_id}/messages/:id")
      end

      # @return [Hash]
      def get_message(channel_id, message_id)
        message = request(:get, "/channels/#{channel_id}/messages/#{message_id}",
                          route: "GET /channels/#{channel_id}/messages/:id")
        assert_own_message!(message)
        message
      end

      # Pages backwards or forwards through a channel.
      #
      # +before+ and +after+ take snowflakes, so {Snowflake.from_time} turns a
      # wall-clock range into a server-side range scan.
      #
      # @param channel_id [String]
      # @param before [String, Integer, nil]
      # @param after [String, Integer, nil]
      # @param limit [Integer]
      # @return [Array<Hash>] our own messages only, newest first
      def list_messages(channel_id, before: nil, after: nil, limit: MESSAGE_PAGE_LIMIT)
        query = { limit: [limit, MESSAGE_PAGE_LIMIT].min }
        query[:before] = before.to_s if before
        query[:after] = after.to_s if after

        messages = request(:get, "/channels/#{channel_id}/messages",
                           query: query,
                           route: "GET /channels/#{channel_id}/messages")

        # A channel is a chat room before it is a table. Anything a human said in
        # it is not ours, is not our business, and is silently skipped.
        Array(messages).select { |message| own_message?(message) }
      end

      # Walks a channel in ascending snowflake order, yielding each of our
      # messages. This is the replay path.
      #
      # @param channel_id [String]
      # @param after [String, Integer, nil] exclusive lower bound
      # @param until_id [String, Integer, nil] inclusive upper bound
      # @yieldparam message [Hash]
      # @return [void]
      def each_message(channel_id, after: nil, until_id: nil)
        return enum_for(:each_message, channel_id, after: after, until_id: until_id) unless block_given?

        cursor = after ? after.to_s : "0"

        loop do
          page = request(:get, "/channels/#{channel_id}/messages",
                         query: { limit: MESSAGE_PAGE_LIMIT, after: cursor },
                         route: "GET /channels/#{channel_id}/messages")
          break if page.nil? || page.empty?

          # With +after+, Discord returns newest-first within the page; ascending
          # order is what a log replay needs.
          page = page.sort_by { |message| message["id"].to_i }

          page.each do |message|
            # Deliberately a non-local exit: passing the upper bound means the
            # caller wants the walk to stop, not just this page.
            return if until_id && message["id"].to_i > until_id.to_i # rubocop:disable Lint/NonLocalExitFromIterator

            yield message if own_message?(message)
          end

          cursor = page.last["id"]
          break if page.size < MESSAGE_PAGE_LIMIT
        end
      end

      # @return [void]
      def delete_message(channel_id, message_id)
        request(:delete, "/channels/#{channel_id}/messages/#{message_id}",
                route: "DELETE /channels/#{channel_id}/messages/:id")
        nil
      end

      # Deletes up to 100 messages in one request. Only works for messages under
      # two weeks old; older ones must go one at a time.
      #
      # @param channel_id [String]
      # @param message_ids [Array<String>]
      # @return [Array<String>] ids that were too old for bulk deletion
      def bulk_delete_messages(channel_id, message_ids)
        ids = Array(message_ids).map(&:to_s)
        return [] if ids.empty?

        cutoff = Time.now - BULK_DELETE_MAX_AGE
        fresh, stale = ids.partition { |id| Snowflake.at(id) > cutoff }

        fresh.each_slice(BULK_DELETE_LIMIT) do |slice|
          if slice.size == 1
            delete_message(channel_id, slice.first)
          else
            request(:post, "/channels/#{channel_id}/messages/bulk-delete",
                    json: { messages: slice },
                    route: "POST /channels/#{channel_id}/messages/bulk-delete")
          end
        end

        stale
      end

      # --- Guild and channel metadata ----------------------------------------

      # @return [Hash]
      def get_guild(guild_id)
        request(:get, "/guilds/#{guild_id}", route: "GET /guilds/#{guild_id}")
      end

      # @return [Hash]
      def get_channel(channel_id)
        request(:get, "/channels/#{channel_id}", route: "GET /channels/#{channel_id}")
      end

      # @return [Hash] the bot's own user object
      def current_user
        request(:get, "/users/@me", route: "GET /users/@me")
      end

      # --- CDN ---------------------------------------------------------------

      # Fetches an attachment from the CDN.
      #
      # The URL must have been resolved from a live message immediately before
      # this call. Discord CDN links carry an HMAC signature over an expiry
      # timestamp and stop working roughly a day after they are issued, so a
      # stored URL is a bug, not a cache.
      #
      # @param url [String]
      # @param range [Range, nil] byte range, if the caller wants a slice
      # @return [String] binary body
      def download(url, range: nil)
        headers = { "User-Agent" => user_agent }
        headers["Range"] = "bytes=#{range.begin}-#{range.end}" if range

        response = @http.call(Request.new(verb: :get, url: url, headers: headers))

        unless response.success?
          raise APIError.new("CDN fetch failed", status: response.status, response_body: response.body)
        end

        response.body
      end

      # --- Guards ------------------------------------------------------------

      # @param message [Hash]
      # @return [Boolean]
      def own_message?(message)
        return true unless config.own_messages_only
        return false unless message.is_a?(Hash)

        message.dig("author", "id").to_s == config.application_id.to_s
      end

      # @raise [ForeignMessageError] if the message was not written by this bot
      # @return [void]
      def assert_own_message!(message)
        return if own_message?(message)

        raise ForeignMessageError,
              "message #{message["id"]} was written by #{message.dig("author", "id").inspect}, " \
              "not by this application (#{config.application_id.inspect}). discord_store only " \
              "reads messages it wrote."
      end

      # @return [void]
      def close
        @http.close if @http.respond_to?(:close)
      end

      private

      def request(method, path, json: nil, body: nil, query: nil, content_type: nil, route: nil)
        route ||= "#{method.to_s.upcase} #{path}"
        url = build_url(path, query)

        headers = {
          "Authorization" => "Bot #{config.token}",
          "User-Agent" => user_agent,
          "Accept" => "application/json"
        }

        if json
          body = JSON.generate(json)
          headers["Content-Type"] = "application/json"
        elsif content_type
          headers["Content-Type"] = content_type
        end

        perform(Request.new(verb: method, url: url, headers: headers, body: body), route)
      end

      def perform(request, route)
        attempt = 0

        loop do
          attempt += 1
          @rate_limiter.acquire(route, timeout: config.quota_timeout)

          response = @http.call(request)
          @rate_limiter.observe(route, response.headers)

          return decode(response) if response.success?

          if response.rate_limited?
            wait = @rate_limiter.penalize(route, response.headers)
            raise_exhausted(route, attempt, response) if attempt > config.max_retries

            log(:warn) { "429 on #{route}; sleeping #{wait}s (attempt #{attempt})" }
            sleep(wait)
            next
          end

          if RETRYABLE_STATUSES.include?(response.status)
            raise_exhausted(route, attempt, response) if attempt > config.max_retries

            backoff = exponential_backoff(attempt)
            log(:warn) { "#{response.status} on #{route}; retrying in #{backoff}s (attempt #{attempt})" }
            sleep(backoff)
            next
          end

          raise_for_status(response, route)
        end
      end

      def decode(response)
        return nil if response.status == 204

        response.json
      end

      def raise_for_status(response, route)
        payload = response.json
        code = payload.is_a?(Hash) ? payload["code"] : nil
        message = payload.is_a?(Hash) ? payload["message"] : response.body
        detail = "#{route} failed with #{response.status}: #{message}"

        case response.status
        when 401, 403
          raise AuthError.new(detail, status: response.status, code: code, response_body: response.body)
        when 404
          raise NotFoundError.new(detail, status: response.status, code: code, response_body: response.body)
        else
          raise APIError.new(detail, status: response.status, code: code, response_body: response.body)
        end
      end

      def raise_exhausted(route, attempt, response)
        raise ExhaustedError,
              "#{route} still failing with #{response.status} after #{attempt - 1} retries"
      end

      # Full jitter: retrying a rate-limited endpoint on a fixed schedule from
      # several workers reproduces the thundering herd that caused the limit.
      def exponential_backoff(attempt)
        ceiling = [2.0**(attempt - 1), 30.0].min
        rand * ceiling
      end

      def build_url(path, query)
        url = "#{config.api_base}#{path}"
        return url if query.nil? || query.empty?

        require "uri"
        "#{url}?#{URI.encode_www_form(query)}"
      end

      def user_agent
        config.user_agent ||
          "DiscordBot (https://github.com/chayuto/discord_store, #{DiscordStore::VERSION})"
      end

      def log(level, &)
        config.logger&.public_send(level, &)
      end
    end
  end
end
