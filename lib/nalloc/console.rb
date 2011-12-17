class Nalloc::Console
  def initialize(io)
    @io = io
    @last_line = nil
    @stack = []
  end

  # Update the console for the duration of the given block. In some cases,
  # move on to the next line.
  def update(props, &b)
    error = true
    @stack.push(props)

    # Prioritize most recent updates.
    merged = {}
    @stack.each { |h| merged.merge!(h) }

    # A simple status line.
    prefix = "Cluster #{merged[:phase]}: "

    line = prefix.dup
    line << "#{merged[:node]}, " if merged[:node]
    line << "#{merged[:operation] || 'in progress'}..."
    rewrite_line(line)

    result = yield
    error = false

    result
  ensure
    @stack.delete(props)

    if phase = props[:phase]
      message = error ? 'error' : 'complete'
      rewrite_line("#{prefix}#{message}.\n")
    end
  end

  private

  # Clear existing line and reset cursor.
  def reset_line
    return unless @last_line

    @io.write("\r#{' ' * @last_line.length}\r")
    @last_line = nil
  end

  # Overwrite the current console line with the given one.
  def rewrite_line(line)
    reset_line
    @io.write(line)
    @last_line = line
  end
end
