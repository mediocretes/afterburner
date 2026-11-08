# frozen_string_literal: true

require_relative "lib/afterburner/version"

Gem::Specification.new do |spec|
  spec.name = "afterburner"
  spec.version = Afterburner::VERSION
  spec.authors = ["Nathan D Acuff"]
  spec.summary = "Write Bitburner scripts in Ruby."
  spec.description = <<~TEXT
    Run real Ruby scripts in the game Bitburner. afterburner serves the game's
    Remote API (replacing bitburner-filesync), runs each .rb script in MRI, and
    sends its ns calls to a small stub the game runs in its place, with the
    script's RAM worked out the way the game does it for JavaScript.
  TEXT
  spec.homepage = "https://github.com/mediocretes/afterburner"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir["lib/**/*.{rb,js}", "exe/*", "README.md", "DESIGN.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["afterburner"]

  spec.add_dependency "async", "~> 2.46"
  spec.add_dependency "async-http", "~> 0.105"
  spec.add_dependency "async-websocket", "~> 0.30"
  spec.add_dependency "irb"
  spec.add_dependency "logger"
  spec.add_dependency "prism", ">= 1.0"
end
