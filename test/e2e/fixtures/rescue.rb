# Game errors arrive as NetscriptError, which a script can rescue.
begin
  ns.hack("n00dles")
rescue NetscriptError => e
  puts "rescued: #{e.message.lines.first.strip}"
end
