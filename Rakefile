# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:ruby) do |task|
  task.libs << "test"
  task.pattern = "test/*_test.rb"
end

desc "Run JavaScript tests"
task :javascript do
  sh "node --test test/site_test.js"
end

desc "Run all tests"
task test: [:ruby, :javascript]
task default: :test
