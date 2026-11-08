# Exercises the everyday API: ARGV, puts/p/warn, snake_case and predicate
# names, namespaces, Records, logger.
name = ARGV.first || "nobody"
puts "Hello, #{name}!"
p [1, :two]
warn "careful"
puts "root on n00dles? #{ns.root_access?('n00dles')}"
puts "n00dles max money: #{ns.format.number(ns.server_max_money('n00dles'), 3)}"
player = ns.player
puts "player money is a #{player.money.class}, hacking skill #{player.skills.hacking}"
logger.info "greeted #{name}"
