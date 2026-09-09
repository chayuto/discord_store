# frozen_string_literal: true

module DiscordStore
  # Discord's message index, exposed deliberately and used for almost nothing.
  #
  # Discord does have a query API. `GET /guilds/{id}/messages/search` takes a
  # full-text `content` filter, channel and author filters, snowflake bounds,
  # attachment filename and extension filters, and sorts by relevance or time.
  # It is more of a query interface than a chat platform owes anybody.
  #
  # It is still not where this library reads from, for four reasons that are
  # Discord's documentation rather than an opinion:
  #
  #   1. It is allowed to under-return. "Search may return slightly fewer
  #      results than the limit specified", and clients "should not rely on the
  #      length of the messages array to paginate". An index that silently drops
  #      rows gives you wrong answers, not slow ones, and a query layer that is
  #      sometimes wrong is worse than no query layer.
  #   2. It is eventually consistent. Fresh messages answer 202 until indexed,
  #      so there is no read-your-writes.
  #   3. It pages at 25 and cannot offset past 9975, capping any single query
  #      at ten thousand rows across four hundred round trips.
  #   4. Everything this library stores is AES-256-GCM ciphertext. Discord's
  #      index tokenises words; there are none. Making the payloads searchable
  #      would mean storing them in the clear on somebody else's servers, which
  #      is a much larger concession than the one on the front of the README.
  #
  # So SQLite remains the query layer, and this exists for the things search is
  # genuinely better at than a channel scan: finding our own messages across a
  # guild without knowing which channel they are in. The metadata it matches on
  # -- the +DS1+ framing prefix and the +.ds1+ attachment extension -- is
  # plaintext already, and deliberately says nothing about the contents.
  #
  # @see DiscordStore::BlobStore#orphans for the reason this was built
  class Search
    # The plaintext framing prefix every message this library writes begins
    # with. Not a secret, and not informative: it identifies the format, not the
    # contents.
    MARKER = "DS1"

    # Attachment extension used by both blob chunks and spilled log records.
    EXTENSION = "ds1"

    # One page. Discord's own maximum.
    PAGE_SIZE = Transport::REST::SEARCH_PAGE_LIMIT

    # A page of results.
    #
    # Deliberately not a bare Array: +total_results+ is documented as
    # inaccurate while messages are being written, and the number of messages
    # returned is documented as possibly fewer than asked for. Handing back an
    # array would invite exactly the +.size+ that Discord says not to trust.
    Result = Struct.new(:messages, :total_results, :indexing, keyword_init: true) do
      include Enumerable

      def each(&) = messages.each(&)

      # @return [Integer] how many came back, which is not how many exist
      def size = messages.size

      def empty? = messages.empty?

      # Always true. Kept as a method so calling code reads honestly.
      #
      # @return [Boolean]
      def approximate? = true

      # @return [Boolean] whether Discord is still backfilling this guild
      def indexing? = !indexing.nil? && indexing
    end

    attr_reader :config

    # @param rest [Transport::REST]
    # @param config [Configuration]
    # @param guild_id [String, nil] defaults to the configured guild
    def initialize(rest:, config:, guild_id: nil)
      @rest = rest
      @config = config
      @guild_id = (guild_id || config.guild_id)&.to_s

      raise ConfigurationError, "guild_id is required to search" if @guild_id.nil? || @guild_id.empty?
    end

    # Searches for messages this bot wrote.
    #
    # @param content [String, nil] full-text filter; only ever matches the
    #   plaintext framing, never a payload
    # @param channel_ids [Array<String>, nil] restrict to these channels
    # @param after [Time, String, Integer, nil] exclusive lower bound
    # @param before [Time, String, Integer, nil] exclusive upper bound
    # @param has [Array<String>, String, nil] e.g. "file"
    # @param attachment_extension [String, nil]
    # @param attachment_filename [String, nil]
    # @param pinned [Boolean, nil]
    # @param sort_by [String, nil] "timestamp" or "relevance"
    # @param sort_order [String, nil] "asc" or "desc"
    # @param limit [Integer]
    # @param offset [Integer]
    # @param author_id [Array<String>, nil] refused while own_messages_only is on
    # @return [Result]
    def messages(content: nil, channel_ids: nil, after: nil, before: nil, has: nil,
                 attachment_extension: nil, attachment_filename: nil, pinned: nil,
                 sort_by: nil, sort_order: nil, limit: PAGE_SIZE, offset: 0, author_id: nil)
      params = {
        content: content,
        channel_id: Array(channel_ids).map(&:to_s),
        min_id: bound(after),
        max_id: bound(before),
        has: Array(has),
        attachment_extension: Array(attachment_extension),
        attachment_filename: Array(attachment_filename),
        pinned: pinned,
        sort_by: sort_by,
        sort_order: sort_order,
        limit: limit.to_i.clamp(1, PAGE_SIZE),
        offset: assert_offset!(offset),
        author_id: scope_authors(author_id)
      }

      body = @rest.search_messages(@guild_id, **params)

      Result.new(
        messages: body["messages"],
        total_results: body["total_results"],
        indexing: body["indexing"]
      )
    end

    # Every message this library wrote, anywhere in the guild.
    #
    # @return [Result]
    def ours(**options) = messages(content: MARKER, **options)

    # Every attachment this library uploaded: blob chunks and spilled records.
    #
    # @return [Result]
    def attachments(**options)
      messages(has: "file", attachment_extension: EXTENSION, **options)
    end

    # Pages through results.
    #
    # Pages by +offset+ rather than by the size of the last page, because
    # Discord says not to paginate on that size. Stops at the offset ceiling
    # with an explicit error rather than quietly returning a truncated set.
    #
    # @yieldparam message [Hash]
    # @return [Enumerator, void]
    def each(**options, &block)
      return enum_for(:each, **options) unless block

      offset = options.delete(:offset).to_i
      seen = 0

      loop do
        page = messages(**options, offset: offset, limit: PAGE_SIZE)
        page.each(&block)

        seen += page.size
        offset += PAGE_SIZE

        break if page.empty? || seen >= page.total_results
        break if exhausted?(offset, page)
      end
    end

    private

    def exhausted?(offset, page)
      return false if offset <= Transport::REST::SEARCH_OFFSET_LIMIT

      raise Error, <<~MSG.strip
        Search cannot be offset past #{Transport::REST::SEARCH_OFFSET_LIMIT}, and this
        query claims #{page.total_results} results. Narrow it with channel_ids or a
        time range; there is no page #{offset}. This is a limit of Discord's index,
        not of this library, and it is one of the reasons reads do not go through it.
      MSG
    end

    # The safety pin.
    #
    # Search reads across a guild rather than a channel it was handed, so it is
    # the one call in this library that could return somebody else's messages.
    # Pinning author_id means the request cannot come back with them in the
    # first place, rather than relying on filtering afterwards -- though
    # {Transport::REST#normalise_search} filters afterwards as well.
    def scope_authors(requested)
      return Array(requested).map(&:to_s) unless config.own_messages_only

      if requested && Array(requested).map(&:to_s) != [config.application_id.to_s]
        raise SearchScopeError, <<~MSG.strip
          Refusing to search for messages written by #{Array(requested).join(", ")}.
          own_messages_only is on, which pins every search to this application's own
          messages. Reading other people's messages is the line between a storage
          backend and a scraper, and search is the endpoint that would cross it.
          Set own_messages_only = false if you genuinely mean to, and know that
          nothing else in this library will help you.
        MSG
      end

      [config.application_id.to_s]
    end

    def assert_offset!(offset)
      value = offset.to_i
      return value if value <= Transport::REST::SEARCH_OFFSET_LIMIT

      raise ArgumentError,
            "offset #{value} exceeds Discord's maximum of #{Transport::REST::SEARCH_OFFSET_LIMIT}"
    end

    def bound(value)
      return nil if value.nil?
      return Snowflake.from_time(value).to_s if value.is_a?(Time)

      value.to_s
    end
  end
end
