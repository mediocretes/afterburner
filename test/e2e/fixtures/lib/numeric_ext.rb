# A library that adds to Ruby's numbers, using ns inside the methods.
class Numeric
  def to_pct = ns.format.percent(self)
end
