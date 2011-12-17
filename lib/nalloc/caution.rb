class Nalloc::Caution

  # Execute a block.  If a log_message has been passed in, swallow and log any
  # exceptions raised by that block of code.
  def self.attempt(log_message)
    yield
  rescue Exception => ex
    if log_message
      exception_error_msg = "#{ex.message}\n\t#{ex.backtrace.join("\n\t")}"
      $stderr.write("#{log_message}: #{exception_error_msg}\n")
    else
      raise ex
    end
  end
end
