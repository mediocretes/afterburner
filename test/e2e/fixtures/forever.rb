# Runs until killed in the game.
at_exit { puts "never seen: the game already closed the connection" }
loop do
  logger.info "tick"
  ns.sleep(200)
end
