# frozen_string_literal: true

require 'bundler/gem_helper'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'ruby-gem-release/workflow/ruby_gem'
require_relative 'scripts/release_preparation'

Bundler::GemHelper.install_tasks

RubyGemRelease::Workflow::RubyGem.new(
  version: RubyGemRelease::Version::RubyConstant.new(path: 'lib/danger-pr-comment/version.rb', constant: 'VERSION'),
  changelog: ReleaseChangelog.new
).install_tasks

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

task default: %i[spec rubocop]
