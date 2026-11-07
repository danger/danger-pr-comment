# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'bundler'
gem 'rake'

group :development do
  gem 'rubocop', '1.82.1'
  gem 'rubocop-rake'
  gem 'rubocop-rspec'
end

group :test do
  gem 'danger-changelog', '~> 0.8', require: false
  gem 'danger-toc', '~> 0.2', require: false
  # Temporary until Danger's git 6 support lands: https://github.com/danger/danger/pull/1561
  gem 'git', '< 6', require: false
  gem 'rspec'
  gem 'simplecov', require: false
  gem 'simplecov-lcov', require: false
end
