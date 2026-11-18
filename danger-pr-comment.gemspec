# frozen_string_literal: true

$LOAD_PATH.push File.expand_path('lib', __dir__)
require 'danger-pr-comment/version'

Gem::Specification.new do |s|
  s.name        = 'danger-pr-comment'
  s.version     = DangerPrComment::VERSION
  s.authors     = ['Andrei Subbota']
  s.email       = ['numbata@users.noreply.github.com']
  s.homepage    = 'https://github.com/danger/danger-pr-comment'
  s.summary     = 'Reusable workflows and shared Dangerfile for PR comment reporting.'
  s.description = 'Shared Dangerfile that exports a JSON report for posting Danger results as a PR comment.'
  s.license     = 'MIT'

  s.files         = Dir['Dangerfile', 'LICENSE.txt', 'README.md', 'lib/**/*.rb', 'bin/*']
  s.require_paths = ['lib']
  s.bindir        = 'bin'
  s.executables   = ['danger-pr-comment']

  s.add_dependency 'danger', '~> 9'
  s.metadata['rubygems_mfa_required'] = 'true'
end
