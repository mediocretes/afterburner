# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs = ["lib", "test"]
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

task default: :test

desc "End-to-end test against the live web game (needs: cd test/e2e && npm install && npx playwright install chromium)"
task :e2e do
  sh "node test/e2e/run.mjs"
end
