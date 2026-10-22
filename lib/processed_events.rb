# example of in memory key store to prevent duplicates. A real receiver should record the key
# in a durable store to prevent dupes.
class ProcessedEvents
  def initialize
    @keys = {}
    @mutex = Mutex.new
  end

  # Returns true and records key if it hasn't been seen; false if it has.
  def first_time?(key)
    @mutex.synchronize do
      next false if @keys.key?(key)

      @keys[key] = true
    end
  end

  def clear
    @mutex.synchronize { @keys.clear }
  end
end
