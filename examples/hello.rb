# Copy into your src/ and run it in the game as: run hello.js world
name = ARGV.first || "Ruby"
puts "Hello, #{name}! This is Ruby #{RUBY_VERSION}, running as pid #{ns.pid}."
puts "home has #{ns.format.ram(ns.server_max_ram('home'))} of RAM; you're at hacking level #{ns.hacking_level}."
logger.info "hello.rb ran with #{ARGV.inspect}"
