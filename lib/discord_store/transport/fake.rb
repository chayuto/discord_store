# frozen_string_literal: true

require "json"
require "time"
require "uri"
require "securerandom"
require_relative "http"

module DiscordStore
  module Transport
    # An in-memory Discord, good enough to develop and test the whole stack
    # against without a bot token.
    #
    # It models the behaviour that actually shapes this library's design, not
    # just the happy path:
    #
    #   * snowflake IDs that really are monotonic and time-encoded
    #   * CDN links that carry an +ex+ expiry and stop working when it passes,
    #     so any code that caches a URL instead of re-resolving it fails here
    #     rather than in production a day after deploy
    #   * rate-limit headers, and 429s on demand
    #   * a two-week bulk-delete window
    #   * messages from other authors, so the own-messages guard is exercised
    #
    # Not a general-purpose Discord mock. It implements exactly the endpoints
    # {REST} calls.
    class Fake
      CDN_HOST = "https://cdn.discordapp.test"
      CDN_TTL = 24 * 60 * 60

      attr_reader :application_id, :channels, :requests

      # @param application_id [String] the id the fake attributes our writes to
      # @param clock [#call] returns a Time; move it forward to test expiry
      # @param rate_limit [Hash] the window the fake advertises in its headers.
      #   Permissive by default so that tests exercise logic rather than sleep;
      #   pass Discord's real per-channel window ({limit: 5, reset_after: 5.0})
      #   when the point of the test is the limiter itself.
      SEARCH_PAGE_SIZE = 25
      SEARCH_OFFSET_CEILING = 9975

      def initialize(application_id: "111111111111111111", clock: -> { Time.now },
                     rate_limit: { limit: 1000, reset_after: 0.05 })
        @application_id = application_id.to_s
        @clock = clock
        @rate_limit = rate_limit
        @channels = Hash.new { |hash, key| hash[key] = [] }
        @attachments = {}
        @guilds = {}
        @requests = []
        @pending_rate_limits = 0
        @sequence = 0
        @search_pending = 0
        @search_under_returns = false
        @search_denied = false
        @mutex = Mutex.new
      end

      # @param request [Request]
      # @return [Response]
      def call(request)
        @mutex.synchronize do
          @requests << request
          uri = URI.parse(request.url)

          return cdn_response(uri) if uri.host == URI.parse(CDN_HOST).host

          if @pending_rate_limits.positive?
            @pending_rate_limits -= 1
            return rate_limited_response
          end

          dispatch(request, uri)
        end
      end

      def close; end

      # --- Test helpers ------------------------------------------------------

      # Registers a guild so chunk-size discovery has something to read.
      #
      # @param id [String]
      # @param premium_tier [Integer] 0..3
      # @return [void]
      def seed_guild(id, premium_tier: 0)
        @guilds[id.to_s] = { "id" => id.to_s, "premium_tier" => premium_tier, "name" => "fake" }
      end

      # Adds a message this library did not write, to prove it gets skipped.
      #
      # @return [Hash] the message
      def seed_foreign_message(channel_id, content:, author_id: "999999999999999999")
        message = build_message(channel_id, content: content, author_id: author_id)
        @channels[channel_id.to_s] << message
        message
      end

      # Makes the next +count+ API calls answer 429.
      #
      # @return [void]
      def inject_rate_limits(count: 1)
        @pending_rate_limits = count
      end

      # @param channel_id [String]
      # @return [Array<Hash>]
      def messages_in(channel_id) = @channels[channel_id.to_s]

      # Makes the next +count+ searches answer 202 "index not yet available",
      # which is what Discord does until it has indexed a guild.
      #
      # @return [void]
      def delay_search_index(count: 1)
        @search_pending = count
      end

      # Makes search return one fewer result per page than it should.
      #
      # Discord documents this: "search may return slightly fewer results than
      # the limit specified". Code that paginates on the size of the returned
      # array silently loses rows, so the fake does it too.
      #
      # @return [void]
      def search_under_returns!
        @search_under_returns = true
      end

      # Makes search answer 403, as it does without the MESSAGE_CONTENT intent.
      #
      # @return [void]
      def deny_search!
        @search_denied = true
      end

      # @return [Integer] total API calls seen, for asserting on request counts
      def request_count = @requests.size

      # @return [Integer] bytes currently held across every attachment
      def stored_bytes = @attachments.values.sum { |a| a[:content].bytesize }

      private

      def dispatch(request, uri)
        method = request.verb.to_s.upcase
        path = uri.path
        pairs = URI.decode_www_form(uri.query.to_s)
        # .to_h keeps only the last value for a repeated key, which is exactly
        # what array query params are, so search gets the pairs instead.
        query = pairs.to_h

        case method
        when "POST"
          case path
          when %r{/channels/(\d+)/messages/bulk-delete\z} then bulk_delete(::Regexp.last_match(1), request)
          when %r{/channels/(\d+)/messages\z} then create_message(::Regexp.last_match(1), request)
          else not_found
          end
        when "PATCH"
          if path =~ %r{/channels/(\d+)/messages/(\d+)\z}
            edit_message(::Regexp.last_match(1), ::Regexp.last_match(2), request)
          else
            not_found
          end
        when "DELETE"
          if path =~ %r{/channels/(\d+)/messages/(\d+)\z}
            delete_message(::Regexp.last_match(1), ::Regexp.last_match(2))
          else
            not_found
          end
        when "GET"
          dispatch_get(path, query, pairs)
        else
          not_found
        end
      end

      def dispatch_get(path, query, pairs = [])
        case path
        when %r{/guilds/(\d+)/messages/search\z}
          search_messages(::Regexp.last_match(1), pairs)
        when %r{/channels/(\d+)/messages/(\d+)\z}
          get_message(::Regexp.last_match(1), ::Regexp.last_match(2))
        when %r{/channels/(\d+)/messages\z}
          list_messages(::Regexp.last_match(1), query)
        when %r{/channels/(\d+)\z}
          ok({ "id" => ::Regexp.last_match(1), "type" => 0 })
        when %r{/guilds/(\d+)\z}
          guild = @guilds[::Regexp.last_match(1)]
          guild ? ok(guild) : not_found
        when %r{/users/@me\z}
          ok({ "id" => @application_id, "bot" => true })
        else
          not_found
        end
      end

      # --- Endpoint implementations -----------------------------------------

      def create_message(channel_id, request)
        payload, files = parse_body(request)

        nonce = payload["nonce"]
        if nonce
          existing = @channels[channel_id].find { |m| m["nonce"] == nonce }
          # Discord deduplicates on nonce within a short window. Modelling it is
          # what makes retry-after-timeout safe to test.
          return ok(existing) if existing
        end

        message = build_message(channel_id, content: payload["content"].to_s, author_id: @application_id)
        message["nonce"] = nonce if nonce

        message["attachments"] = files.map.with_index do |file, index|
          store_attachment(channel_id, message["id"], index, file)
        end

        @channels[channel_id] << message
        ok(message)
      end

      def edit_message(channel_id, message_id, request)
        message = find_message(channel_id, message_id)
        return not_found unless message

        payload, = parse_body(request)
        message["content"] = payload["content"].to_s
        message["edited_timestamp"] = @clock.call.utc.iso8601
        ok(message)
      end

      def get_message(channel_id, message_id)
        message = find_message(channel_id, message_id)
        return not_found unless message

        ok(refresh_attachment_urls(message))
      end

      def list_messages(channel_id, query)
        limit = (query["limit"] || 50).to_i
        messages = @channels[channel_id].sort_by { |m| m["id"].to_i }

        if (after = query["after"])
          messages = messages.select { |m| m["id"].to_i > after.to_i }
          messages = messages.first(limit)
        elsif (before = query["before"])
          messages = messages.select { |m| m["id"].to_i < before.to_i }
          messages = messages.last(limit)
        else
          messages = messages.last(limit)
        end

        # Discord returns newest first.
        ok(messages.reverse.map { |m| refresh_attachment_urls(m) })
      end

      def delete_message(channel_id, message_id)
        removed = @channels[channel_id].reject! { |m| m["id"] == message_id.to_s }
        return not_found if removed.nil?

        Response.new(status: 204, headers: rate_limit_headers, body: nil)
      end

      def bulk_delete(channel_id, request)
        payload, = parse_body(request)
        ids = Array(payload["messages"]).map(&:to_s)

        cutoff = @clock.call - REST::BULK_DELETE_MAX_AGE
        if ids.any? { |id| Snowflake.at(id) <= cutoff }
          return Response.new(
            status: 400,
            headers: rate_limit_headers,
            body: JSON.generate({
                                  "code" => 50_034,
                                  "message" => "You can only bulk delete messages that are " \
                                               "under 14 days old."
                                })
          )
        end

        @channels[channel_id].reject! { |m| ids.include?(m["id"]) }
        Response.new(status: 204, headers: rate_limit_headers, body: nil)
      end

      # Discord's message search, including the parts that make it unsuitable
      # as a read path. A generous fake here would let code ship that breaks
      # the first time the index lags or drops a row.
      # +guild_id+ is unused: the fake holds one guild's worth of channels, and
      # the parameter is kept so the signature matches the endpoint it models.
      def search_messages(_guild_id, pairs)
        return forbidden("Missing Access") if @search_denied

        if @search_pending.positive?
          @search_pending -= 1
          return index_not_ready
        end

        params = group_params(pairs)
        matches = search_candidates(params)
        window = search_window(matches, params)

        ok({
             "total_results" => matches.size,
             "doing_deep_historical_index" => false,
             # Nested one deep: the shape Discord kept after it stopped
             # returning the surrounding context of each hit.
             "messages" => window.map { |message| [message] }
           })
      end

      def search_candidates(params)
        all = @channels.flat_map { |channel_id, messages| messages.map { |m| [channel_id, m] } }

        all.select { |channel_id, message| search_match?(channel_id, message, params) }
           .map { |_, message| message }
           .sort_by { |message| -message["id"].to_i }
      end

      def search_match?(channel_id, message, params)
        search_scope_match?(channel_id, message, params) &&
          search_bounds_match?(message, params) &&
          search_body_match?(message, params)
      end

      def search_scope_match?(channel_id, message, params)
        authors = params["author_id"]
        channels = params["channel_id"]

        return false if authors.any? && !authors.include?(message.dig("author", "id"))
        return false if channels.any? && !channels.include?(channel_id)

        true
      end

      def search_bounds_match?(message, params)
        id = message["id"].to_i
        min = params["min_id"].first
        max = params["max_id"].first

        return false if min && id <= min.to_i
        return false if max && id >= max.to_i

        true
      end

      def search_body_match?(message, params)
        content = params["content"]

        return false if content.any? && !search_content_match?(message, content)
        return false if params["has"].include?("file") && Array(message["attachments"]).empty?

        search_attachment_match?(message, params)
      end

      def search_content_match?(message, needles)
        haystack = message["content"].to_s.downcase
        needles.all? { |needle| haystack.include?(needle.to_s.downcase) }
      end

      def search_attachment_match?(message, params)
        extensions = params["attachment_extension"]
        filenames = params["attachment_filename"]
        return true if extensions.empty? && filenames.empty?

        names = Array(message["attachments"]).map { |a| a["filename"].to_s }
        return false if extensions.any? && names.none? { |n| extensions.include?(n.split(".").last) }
        return false if filenames.any? && names.none? { |n| filenames.include?(n) }

        true
      end

      def search_window(matches, params)
        limit = (params["limit"].first || SEARCH_PAGE_SIZE).to_i.clamp(1, SEARCH_PAGE_SIZE)
        offset = (params["offset"].first || 0).to_i
        return [] if offset > SEARCH_OFFSET_CEILING

        window = matches.slice(offset, limit) || []
        # "Search may return slightly fewer results than the limit specified."
        window = window[0...-1] if @search_under_returns && window.size > 1
        window
      end

      def group_params(pairs)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        pairs.each { |key, value| grouped[key] << value }
        grouped
      end

      def index_not_ready
        Response.new(
          status: 202,
          headers: rate_limit_headers.merge("content-type" => "application/json"),
          body: JSON.generate({
                                "message" => "Index not yet available. Try again later",
                                "code" => 110_000,
                                "documents_indexed" => 0,
                                "retry_after" => 0
                              })
        )
      end

      def forbidden(message)
        Response.new(
          status: 403,
          headers: rate_limit_headers.merge("content-type" => "application/json"),
          body: JSON.generate({ "message" => message, "code" => 50_001 })
        )
      end

      def cdn_response(uri)
        segments = uri.path.split("/").reject(&:empty?)
        attachment_id = segments[2]
        record = @attachments[attachment_id]
        return not_found unless record

        pairs = URI.decode_www_form(uri.query.to_s)
        # .to_h keeps only the last value for a repeated key, which is exactly
        # what array query params are, so search gets the pairs instead.
        query = pairs.to_h
        expires_at = query["ex"].to_s.to_i(16)

        # The whole point of the fake: an expired link 404s, exactly as Discord's
        # has since it started signing them.
        if expires_at.positive? && @clock.call.to_i > expires_at
          return Response.new(status: 404, headers: {},
                              body: "This content is no longer available.")
        end

        Response.new(status: 200, headers: { "content-type" => "application/octet-stream" },
                     body: record[:content])
      end

      # --- Helpers -----------------------------------------------------------

      def build_message(channel_id, content:, author_id:)
        {
          "id" => next_snowflake,
          "channel_id" => channel_id.to_s,
          "content" => content,
          "author" => { "id" => author_id.to_s, "bot" => author_id.to_s == @application_id },
          "timestamp" => @clock.call.utc.iso8601,
          "attachments" => [],
          "pinned" => false
        }
      end

      def store_attachment(channel_id, _message_id, index, file)
        id = next_snowflake
        @attachments[id] = { content: file[:content].to_s.dup.force_encoding(Encoding::BINARY),
                             filename: file[:filename] }

        {
          "id" => id,
          "filename" => file[:filename],
          "size" => file[:content].to_s.bytesize,
          "url" => signed_url(channel_id, id, file[:filename]),
          "_index" => index
        }
      end

      # Every read re-signs, exactly as Discord does. Code that stores the URL
      # from a previous read instead of re-fetching the message will pass the
      # first test and fail once the clock moves.
      def refresh_attachment_urls(message)
        copy = message.dup
        copy["attachments"] = message["attachments"].map do |attachment|
          url = signed_url(message["channel_id"], attachment["id"], attachment["filename"])
          attachment.merge("url" => url)
        end
        copy
      end

      def signed_url(channel_id, attachment_id, filename)
        issued = @clock.call.to_i
        expires = issued + CDN_TTL
        # A real HMAC over Discord's private key; here, any opaque value.
        hmac = SecureRandom.hex(16)
        "#{CDN_HOST}/attachments/#{channel_id}/#{attachment_id}/#{filename}" \
          "?ex=#{expires.to_s(16)}&is=#{issued.to_s(16)}&hm=#{hmac}"
      end

      def find_message(channel_id, message_id)
        @channels[channel_id.to_s].find { |m| m["id"] == message_id.to_s }
      end

      def next_snowflake
        @sequence += 1
        (Snowflake.from_time(@clock.call) | (@sequence & Snowflake::INCREMENT_MASK)).to_s
      end

      def parse_body(request)
        content_type = (request.headers || {}).fetch("Content-Type", "")

        if content_type.start_with?("multipart/form-data")
          parse_multipart(request.body, content_type)
        else
          [JSON.parse(request.body.to_s), []]
        end
      rescue JSON::ParserError
        [{}, []]
      end

      def parse_multipart(body, content_type)
        boundary = content_type[/boundary=(.+)\z/, 1]
        return [{}, []] unless boundary

        payload = {}
        files = []

        body.to_s.split("--#{boundary}").each do |part|
          headers, content = part.split("\r\n\r\n", 2)
          next unless headers && content

          content = content.sub(/\r\n\z/, "")

          if headers.include?('name="payload_json"')
            payload = JSON.parse(content)
          elsif (filename = headers[/filename="([^"]*)"/, 1])
            files << { filename: filename, content: content }
          end
        end

        [payload, files]
      end

      def ok(payload)
        Response.new(status: 200, headers: rate_limit_headers, body: JSON.generate(payload))
      end

      def not_found
        Response.new(status: 404, headers: rate_limit_headers,
                     body: JSON.generate({ "code" => 10_008, "message" => "Unknown Message" }))
      end

      def rate_limited_response
        Response.new(
          status: 429,
          headers: rate_limit_headers.merge(
            "x-ratelimit-remaining" => "0",
            "x-ratelimit-reset-after" => "0.01",
            "retry-after" => "0.01",
            "x-ratelimit-scope" => "user"
          ),
          body: JSON.generate({ "message" => "You are being rate limited.", "retry_after" => 0.01 })
        )
      end

      def rate_limit_headers
        limit = @rate_limit[:limit]
        {
          "x-ratelimit-bucket" => "fake-bucket",
          "x-ratelimit-limit" => limit.to_s,
          "x-ratelimit-remaining" => (limit - 1).to_s,
          "x-ratelimit-reset-after" => @rate_limit[:reset_after].to_s
        }
      end
    end
  end
end
