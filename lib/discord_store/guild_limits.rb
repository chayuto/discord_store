# frozen_string_literal: true

module DiscordStore
  # Discovers how large an attachment this guild will actually accept.
  #
  # Every previous library in this genre hardcoded the number, and every one of
  # them broke, because Discord has moved it repeatedly and in both directions:
  # 8 MiB for years, then 25 MB, then back to 10 MB, with boosted guilds on a
  # different ladder again. Published write-ups from 2023 and 2026 disagree,
  # and both were right when they were written.
  #
  # So the number is treated as a fact about the running system rather than a
  # constant. The tier table below is a conservative starting point; {#probe!}
  # measures the truth by trying.
  class GuildLimits
    MIB = 1024 * 1024

    # Deliberately pessimistic. Being wrong low costs a few extra chunks; being
    # wrong high costs a failed upload halfway through a large file.
    TIER_LIMITS = {
      0 => 10 * MIB,
      1 => 10 * MIB,
      2 => 50 * MIB,
      3 => 100 * MIB
    }.freeze

    FALLBACK_LIMIT = 8 * MIB

    # Room for multipart framing, the payload_json part, and headers, so that a
    # chunk sized at exactly the ceiling does not push the request over it.
    REQUEST_OVERHEAD = 16 * 1024

    def initialize(rest:, config:)
      @rest = rest
      @config = config
      @mutex = Mutex.new
    end

    # Largest attachment this guild accepts, in bytes.
    #
    # @param refresh [Boolean]
    # @return [Integer]
    def attachment_limit(refresh: false)
      @mutex.synchronize do
        @attachment_limit = nil if refresh
        @attachment_limit ||= discover_limit
      end
    end

    # Bytes per blob chunk: the attachment ceiling less request overhead, unless
    # the caller pinned it in configuration.
    #
    # @return [Integer]
    def chunk_size
      @config.chunk_size || (attachment_limit - REQUEST_OVERHEAD)
    end

    # Measures the real ceiling by binary search, uploading and then deleting
    # throwaway attachments.
    #
    # Costs a handful of requests and writes garbage into the channel briefly,
    # so it is opt-in. Run it once at deploy time and pin the result in
    # configuration rather than probing on every boot.
    #
    # @param channel_id [String] a channel safe to write junk into
    # @param low [Integer] known-good size
    # @param high [Integer] known-or-suspected-bad size
    # @param precision [Integer] stop when the bracket is this narrow
    # @return [Integer] the largest size that succeeded
    def probe!(channel_id:, low: MIB, high: 100 * MIB, precision: MIB / 4)
      raise ArgumentError, "low must be under high" unless low < high

      best = nil

      while high - low > precision
        midpoint = low + ((high - low) / 2)

        if upload_succeeds?(channel_id, midpoint)
          best = midpoint
          low = midpoint
        else
          high = midpoint
        end
      end

      best ||= low
      @mutex.synchronize { @attachment_limit = best }
      best
    end

    private

    def discover_limit
      return @config.chunk_size + REQUEST_OVERHEAD if @config.chunk_size
      return FALLBACK_LIMIT unless @config.guild_id

      guild = @rest.get_guild(@config.guild_id)
      tier = guild["premium_tier"].to_i
      TIER_LIMITS.fetch(tier, FALLBACK_LIMIT)
    rescue APIError
      # A store that cannot read its own guild can still write small chunks.
      FALLBACK_LIMIT
    end

    def upload_succeeds?(channel_id, size)
      message = @rest.create_message(
        channel_id,
        content: "DS1 probe #{size}",
        files: [{ filename: "probe.bin", content: "\0" * size, content_type: "application/octet-stream" }]
      )
      @rest.delete_message(channel_id, message["id"])
      true
    rescue APIError, ExhaustedError
      false
    end
  end
end
