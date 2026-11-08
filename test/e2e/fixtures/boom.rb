# Raises from inside a method, to check the backtrace reaches the game.
def explode(what)
  raise "#{what} went boom"
end

explode("the reactor")
