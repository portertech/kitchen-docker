require "bundler/gem_tasks"
require 'cane/rake_task'
require 'tailor/rake_task'

desc "Run cane to check quality metrics"
Cane::RakeTask.new do |cane|
  cane.canefile = './.cane'
end

Tailor::RakeTask.new

desc "Display LOC stats"
task :stats do
  puts "\n## Production Code Stats"
  sh "countloc -r lib"
end

desc "lint YAML files"
task :yaml_lint do
  sh 'yaml-lint ./.travis.yml'
  sh 'yaml-lint ./.kitchen.yml'
end

desc "Run all quality tasks"
task :quality => [:cane, :tailor, :stats, :yaml_lint]

task :default => [:quality]

begin
  require 'kitchen/rake_tasks'
  Kitchen::RakeTasks.new
rescue LoadError
  puts ">>>>> Kitchen gem not loaded, omitting tasks" unless ENV['CI']
end
