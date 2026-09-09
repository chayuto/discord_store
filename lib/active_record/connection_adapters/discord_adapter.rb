# frozen_string_literal: true

require "discord_store"
require "active_record/connection_adapters/sqlite3_adapter"
require "discord_store/journal"
require "discord_store/replay"

module ActiveRecord
  module ConnectionAdapters
    # An ActiveRecord adapter whose durable store is a Discord channel.
    #
    #   # config/database.yml
    #   development:
    #     adapter: discord
    #     database: storage/development.sqlite3
    #     discord:
    #       i_understand_this_violates_discord_tos: true
    #       token: <%= ENV["DISCORD_BOT_TOKEN"] %>
    #       application_id: <%= ENV["DISCORD_APPLICATION_ID"] %>
    #       secret_key: <%= ENV["DISCORD_STORE_KEY"] %>
    #       log_channel_ids: ["1234567890"]
    #
    # == What this actually is
    #
    # It is a SQLite adapter that mirrors every write into a Discord channel,
    # and it is cheating. The README says so too. Here is why it cheats.
    #
    # Discord gives a bot no query interface whatsoever. There is no WHERE, no
    # index, no server-side filter; there is a channel you may page through a
    # hundred messages at a time. Answering +User.where(email: ...)+ against
    # that means scanning the channel, which is why the honest implementations
    # of this idea top out at a few megabytes per second and cannot do a join at
    # all.
    #
    # So Discord is not asked to be a query engine. It is asked to be the
    # durable, replicated, ordered write-ahead log — a thing it is unexpectedly
    # decent at, because message IDs are snowflakes and therefore already a
    # monotonic sequence with a timestamp in them — and a local SQLite file is
    # the materialized view you actually query. Writes go to the log first, then
    # to SQLite. Reads never touch the network. +rake discord:replay+ rebuilds
    # the SQLite file from the channel, from empty, on any machine.
    #
    # That is a materialized view over a replicated log, which is a normal thing
    # that normal systems do. The unusual part is only where the log lives.
    #
    # == What it costs
    #
    # A transaction is one message, and a channel accepts about five messages
    # every five seconds. So this adapter sustains roughly *one write
    # transaction per second*. That is not a tuning problem, it is the platform,
    # and it is why +journal_mode: :async+ exists (batching many transactions
    # into one message, at the cost of a durability window) and why writes are
    # not sharded across channels by default (a write-ahead log with no total
    # order is not a write-ahead log).
    #
    # Reads are as fast as SQLite, which is to say, fast.
    class DiscordAdapter < SQLite3Adapter
      ADAPTER_NAME = "Discord"

      # Statements that mutate. Everything else is served locally and never
      # reaches the network.
      WRITE_STATEMENT = /\A\s*(?:INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP|TRUNCATE)\b/i

      # Statements whose result depends on when they run, and which therefore
      # cannot be replayed faithfully.
      NON_DETERMINISTIC = /\b(?:RANDOM|CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME)\s*(?:\(\s*\))?/i

      class << self
        # Rails calls this to build the underlying SQLite connection; the Discord
        # half is set up in #initialize, after super.
        def new_client(config)
          super(config.except(:discord, :journal_mode, :replay_on_connect))
        end
      end

      # @return [DiscordStore::Journal]
      attr_reader :journal

      def initialize(...)
        super
        @discord_config = extract_discord_config
        @journal = build_journal
        @statement_buffer = nil
        replay_on_connect! if @discord_config[:replay_on_connect]
      end

      # --- Write interception -------------------------------------------------

      def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil, returning: nil)
        record_statement(sql, binds)
        super
      end

      def exec_update(sql, name = nil, binds = [])
        record_statement(sql, binds)
        super
      end

      def exec_delete(sql, name = nil, binds = [])
        record_statement(sql, binds)
        super
      end

      # Catches DDL, which migrations issue through #execute rather than through
      # the exec_* trio. A migration is a write to the log like any other, which
      # is what makes a replay onto an empty file reproduce the schema as well as
      # the rows.
      def execute(sql, name = nil, **kwargs)
        record_statement(sql, []) if sql.is_a?(String) && WRITE_STATEMENT.match?(sql)
        super
      end

      # --- Transactions -------------------------------------------------------

      # Note the absence of a begin_db_transaction override.
      #
      # Rails materialises transactions lazily: the first write inside a
      # transaction reaches #exec_insert before BEGIN is ever sent. An override
      # here that initialised the statement buffer would therefore throw that
      # first statement away, which is why #record_statement asks the
      # transaction manager whether a transaction is open instead of trusting a
      # callback that has not fired yet.
      #
      # The log is written before SQLite commits, not after.
      #
      # There is no two-phase commit available between a SQLite file and a chat
      # server, so one of them has to go first and the other has to be the one
      # that can be reconstructed. Writing the log first means a crash in between
      # leaves a record that replay will apply, and the local file catches up.
      # Committing first would leave rows that exist nowhere else, which in a
      # design where the log is the source of truth is simply data loss.
      def commit_db_transaction
        flush_buffer!
        super
      end

      def exec_rollback_db_transaction
        @statement_buffer = nil
        super
      end

      # --- Log operations -----------------------------------------------------

      # Rebuilds this connection's SQLite database from the Discord log.
      #
      # @param from [String, nil] cursor to resume from; nil replays everything
      # @return [Hash] {applied:, skipped:, cursor:}
      def replay!(from: nil)
        DiscordStore::Replay.new(connection: self, journal: @journal).call(from: from)
      end

      # @return [String, nil] cursor of the newest record in the log
      def log_tip = @journal.tip

      # Everything the local file has that the log does not, and vice versa.
      #
      # @return [Hash]
      def log_status
        { local_cursor: @journal.local_cursor, remote_cursor: @journal.tip,
          pending: @journal.pending_count, mode: @journal.mode }
      end

      # Flushes anything buffered by +journal_mode: :async+.
      #
      # @return [Integer] records written
      def flush_journal! = @journal.flush!

      def supports_savepoints? = true

      # Discord cannot participate in a savepoint: a message, once sent, is sent.
      # Statements inside a savepoint that later rolls back would still be in the
      # log, so replay would apply work the database rolled back.
      def create_savepoint(name = current_savepoint_name)
        if @journal.recording?
          raise DiscordStore::Error,
                "savepoints cannot be journalled: a sent message cannot be un-sent, so a " \
                "rolled-back savepoint would still replay. Set journal_mode: :off for this " \
                "connection, or avoid nested transactions with requires_new: true."
        end

        super
      end

      def disconnect!
        @journal.flush! if @journal&.recording?
        super
      end

      private

      def record_statement(sql, binds)
        return unless @journal.recording?
        return unless sql.is_a?(String)

        # Replay's own bookkeeping table is local state about the log. Writing it
        # into the log would make every replay append the record of itself.
        return if sql.include?(DiscordStore::Journal::CURSOR_TABLE)

        warn_non_deterministic(sql)

        entry = { "sql" => sql, "binds" => DiscordStore::Journal.serialize_binds(binds) }

        if in_open_transaction?
          (@statement_buffer ||= []) << entry
        else
          # An autocommit write is a transaction of one.
          @journal.write([entry])
        end
      end

      # True from the moment Rails opens a transaction object, which is before it
      # bothers to send BEGIN.
      def in_open_transaction?
        current = transaction_manager.current_transaction
        current.respond_to?(:open?) && current.open?
      rescue StandardError
        false
      end

      def flush_buffer!
        buffered = @statement_buffer
        @statement_buffer = nil
        return if buffered.nil? || buffered.empty?

        @journal.write(buffered)
      end

      # Rails sends timestamps as bind parameters, so this fires rarely; when it
      # does, the statement will replay to a different value than it produced,
      # and silence would be the wrong response.
      def warn_non_deterministic(sql)
        return unless NON_DETERMINISTIC.match?(sql)

        message = "discord_store: journalled a non-deterministic statement; a replay will " \
                  "not reproduce this row exactly: #{sql[0, 200]}"
        (@discord_config[:logger] || ActiveRecord::Base.logger)&.warn(message)
      end

      def extract_discord_config
        raw = @config[:discord] || @config["discord"] || {}
        raw.to_h.transform_keys(&:to_sym).tap do |options|
          options[:journal_mode] = (options[:journal_mode] || @config[:journal_mode] || :sync).to_sym
          options[:replay_on_connect] = @config[:replay_on_connect] || options[:replay_on_connect]
        end
      end

      def build_journal
        DiscordStore::Journal.new(
          config: DiscordStore::Journal.build_configuration(@discord_config),
          mode: @discord_config[:journal_mode],
          http: @discord_config[:http] # injectable for tests
        )
      end

      def replay_on_connect!
        replay!
      rescue DiscordStore::Error => e
        (@discord_config[:logger] || ActiveRecord::Base.logger)&.error(
          "discord_store: replay on connect failed: #{e.message}"
        )
        raise
      end
    end
  end
end

ActiveRecord::ConnectionAdapters.register(
  "discord",
  "ActiveRecord::ConnectionAdapters::DiscordAdapter",
  "active_record/connection_adapters/discord_adapter"
)
