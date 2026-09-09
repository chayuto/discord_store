# frozen_string_literal: true

module DiscordStore
  # Rebuilds a local database from the Discord log.
  #
  # This is the operation that decides whether any of this is a real design or a
  # stunt. If the channel is the source of truth, then a machine holding no
  # local file must be able to reach the same state by reading it, and it must
  # reach the *same* state every time. That is the whole contract:
  #
  #   rm storage/production.sqlite3 && rake discord:replay
  #
  # should leave the database exactly as it was, on any machine, from nothing
  # but a bot token and a channel ID.
  #
  # Statements replay inside a local transaction per journalled transaction, so
  # a batch that was atomic when written is atomic when replayed.
  class Replay
    # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @param journal [Journal]
    def initialize(connection:, journal:)
      @connection = connection
      @journal = journal
    end

    # @param from [String, nil] cursor to resume after; nil replays everything
    # @param progress [#call, nil] called with (applied, cursor) periodically
    # @return [Hash] {applied:, statements:, cursor:, skipped:}
    def call(from: nil, progress: nil)
      applied = 0
      statements = 0
      skipped = 0
      cursor = from

      # Replay is a rewrite of local state from the log, so it must not be
      # journalled back into the log. Without this a replay would duplicate
      # every transaction it read.
      @journal.while_paused do
        # Inside the pause, because reading the stored cursor creates the
        # bookkeeping table, and that DDL must not become a log entry.
        from ||= stored_cursor
        cursor = from

        @journal.each_transaction(from: from) do |entry, record_cursor|
          begin
            apply(entry["tx"])
            applied += 1
            statements += entry["tx"].size
          rescue StandardError => e
            skipped += 1
            warn "discord_store: replay skipped #{record_cursor}: #{e.class}: #{e.message}"
          end

          cursor = record_cursor
          store_cursor(cursor)
          progress&.call(applied, cursor)
        end
      end

      @journal.local_cursor = cursor
      { applied: applied, statements: statements, cursor: cursor, skipped: skipped }
    end

    # How far behind the local database is.
    #
    # @return [Hash] {local:, remote:, behind:}
    def status
      local = stored_cursor
      remote = @journal.tip
      { local: local, remote: remote, behind: local != remote }
    end

    private

    def apply(transaction)
      @connection.transaction(requires_new: true) do
        transaction.each do |statement|
          sql = statement["sql"]
          binds = Journal.deserialize_binds(statement["binds"])

          if binds.empty?
            @connection.execute(sql)
          else
            @connection.exec_query(sql, "Replay", type_casted_binds(sql, binds))
          end
        end
      end
    end

    # Binds arrive as plain values, but exec_query wants attribute objects.
    #
    # Binary values need the binary type specifically: handed to the generic
    # value type, SQLite's adapter tries to read them as UTF-8 and a byte like
    # 0xFF ends the replay.
    def type_casted_binds(_sql, binds)
      binds.map do |value|
        type = if value.is_a?(String) && (value.encoding == Encoding::BINARY || !value.valid_encoding?)
                 ActiveModel::Type::Binary.new
               else
                 ActiveModel::Type::Value.new
               end

        ActiveRecord::Relation::QueryAttribute.new(nil, value, type)
      end
    end

    def stored_cursor
      ensure_cursor_table
      row = @connection.select_one("SELECT cursor FROM #{Journal::CURSOR_TABLE} WHERE id = 1")
      row && row["cursor"]
    end

    def store_cursor(cursor)
      return if cursor.nil?

      ensure_cursor_table
      quoted = @connection.quote(cursor)
      @connection.execute(
        "INSERT INTO #{Journal::CURSOR_TABLE} (id, cursor) VALUES (1, #{quoted}) " \
        "ON CONFLICT(id) DO UPDATE SET cursor = #{quoted}"
      )
    end

    def ensure_cursor_table
      return if @cursor_table_ready

      @connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{Journal::CURSOR_TABLE} (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          cursor TEXT
        )
      SQL
      @cursor_table_ready = true
    end
  end
end
