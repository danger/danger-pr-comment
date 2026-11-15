# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'yaml'

RSpec.describe 'Current PR matching workflow' do
  let(:workflow) { YAML.load_file(File.expand_path('../../.github/workflows/danger-comment.yml', __dir__)) }
  let(:run) do
    {
      id: 123, event: 'pull_request', conclusion: 'success', created_at: '2026-11-15T10:00:00Z',
      head_sha: 'abc123', head_branch: 'contribution', head_repository: { id: 42, owner: { login: 'contributor' } },
      pull_requests: []
    }
  end
  let(:pr) do
    {
      number: 7, state: 'open', created_at: '2026-11-15T09:00:00Z',
      head: { sha: 'abc123', ref: 'contribution', repo: { id: 42 } },
      base: { ref: 'main', repo: { id: 1 } }
    }
  end
  let(:fixture) do
    job = workflow.fetch('jobs').fetch('comment')
    step = job.fetch('steps').last
    {
      condition: job.fetch('if'), script: step.fetch('with').fetch('script'), environment: step.fetch('env'),
      inputs: workflow.fetch('on', workflow[true]).fetch('workflow_call').fetch('inputs')
                      .transform_values { |input| input.fetch('default', '') },
      context: {
        eventName: 'workflow_run', repo: { owner: 'danger', repo: 'example' }, serverUrl: 'https://github.com',
        payload: { workflow_run: run, repository: { id: 1, default_branch: 'main' } }
      },
      report: { pr_number: 7 }, pulls: [JSON.parse(JSON.generate(pr), symbolize_names: true)], pr: pr, comments: []
    }
  end

  def execute_workflow(**overrides)
    harness = File.expand_path('../fixtures/run_current_pr_workflow.js', __dir__)
    stdout, stderr, status = Open3.capture3('node', harness, stdin_data: JSON.generate(fixture.merge(overrides)))
    raise "Node workflow harness failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def expect_rejection(**overrides)
    result = execute_workflow(**overrides)
    expect(result.fetch('failures')).not_to be_empty
    expect(result.fetch('calls').map { |call| call.fetch('method') }).not_to include('listComments', 'createComment', 'updateComment')
    result
  end

  def irrelevant_pulls(count)
    Array.new(count) { |index| pr.merge(number: index + 100, head: pr.fetch(:head).merge(repo: { id: 99 })) }
  end

  it 'resolves a fork PR independently of an empty workflow-run association array' do
    result = execute_workflow

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').first).to include('method' => 'listPulls', 'owner' => 'danger', 'repo' => 'example',
                                                   'state' => 'open', 'head' => 'contributor:contribution', 'per_page' => 100)
    expect(result.fetch('calls').first).not_to have_key('base')
    expect(result.fetch('calls').last).to include('method' => 'createComment', 'issue_number' => 7)
  end

  it 'updates an existing report for a failed PR run' do
    run[:conclusion] = 'failure'
    result = execute_workflow(comments: [{ id: 10, user: { login: 'github-actions[bot]', type: 'Bot' }, body: "<!-- danger-report -->\nOld report" }])

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').last).to include('method' => 'updateComment', 'comment_id' => 10)
  end

  it 'accepts a source branch in the caller repository' do
    run[:head_repository][:id] = pr[:head][:repo][:id] = 1
    run[:head_repository][:owner][:login] = 'danger'

    expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'requires an explicit wildcard to follow an upper stacked target' do
    pr[:base][:ref] = 'feature/lower'
    expect_rejection
    fixture[:inputs]['base-branch'] = '*'

    expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'supports a literal trusted base override' do
    pr[:base][:ref] = 'release'
    fixture[:inputs]['base-branch'] = 'release'

    expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'uses the caller repository default rather than assuming main' do
    pr[:base][:ref] = 'trunk'
    fixture[:context][:payload][:repository][:default_branch] = 'trunk'

    expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'does not let a literal override accept another current base' do
    fixture[:inputs]['base-branch'] = 'release'

    expect_rejection
  end

  it 'rejects a forged report number without fetching that PR' do
    result = expect_rejection(report: { pr_number: 8 })

    expect(result.fetch('calls')).to contain_exactly(include('method' => 'listPulls'))
  end

  it 'rejects a source shared by multiple open PRs before applying an explicit base policy' do
    fixture[:inputs]['base-branch'] = 'main'
    result = expect_rejection(pulls: [pr, pr.merge(number: 8, base: { ref: 'feature/lower', repo: { id: 1 } })])

    expect(result.fetch('calls')).to contain_exactly(include('method' => 'listPulls'))
  end

  it 'finds a unique source match beyond the first page' do
    result = execute_workflow(pulls: irrelevant_pulls(100) + [pr])

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').select { |call| call['method'] == 'listPulls' }.map { |call| call['page'] }).to eq([1, 2])
    expect(result.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'does not stop looking for ambiguity after finding a match on the first page' do
    result = expect_rejection(pulls: [pr] + irrelevant_pulls(99) + [pr.merge(number: 8)])

    expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(%w[listPulls listPulls])
  end

  it 'fails closed if a later page is inaccessible even after finding a match' do
    expect_rejection(pulls: [pr] + irrelevant_pulls(99), failPage: 2)
  end

  it 'does not confuse other branches sharing the same commit with the run source' do
    result = execute_workflow(pulls: [pr, pr.merge(number: 8, head: pr.fetch(:head).merge(ref: 'other'))])

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').last).to include('method' => 'createComment', 'issue_number' => 7)
  end

  [nil, 0, -1, 1.5, true, '7', 9_007_199_254_740_992].each do |number|
    it "rejects invalid report PR number #{number.inspect} before API access" do
      expect(expect_rejection(report: { pr_number: number }).fetch('calls')).to be_empty
    end
  end

  {
    'commit' => ->(run) { run[:head_sha] = nil },
    'nonstring commit' => ->(run) { run[:head_sha] = 123 },
    'branch' => ->(run) { run[:head_branch] = '' },
    'nonstring branch' => ->(run) { run[:head_branch] = 123 },
    'source repository' => ->(run) { run[:head_repository] = nil },
    'source repository ID' => ->(run) { run[:head_repository][:id] = '42' },
    'zero repository ID' => ->(run) { run[:head_repository][:id] = 0 },
    'source owner' => ->(run) { run[:head_repository][:owner] = nil },
    'empty source owner' => ->(run) { run[:head_repository][:owner][:login] = '' },
    'creation time' => ->(run) { run[:created_at] = nil },
    'invalid creation time' => ->(run) { run[:created_at] = 'not-a-date' },
    'nonstring creation time' => ->(run) { run[:created_at] = 0 }
  }.each do |name, change|
    it "rejects missing or invalid run #{name} before API access" do
      change.call(run)

      expect(expect_rejection.fetch('calls')).to be_empty
    end
  end

  {
    'commit' => ->(pr) { pr[:head][:sha] = 'new-commit' },
    'branch' => ->(pr) { pr[:head][:ref] = 'other' },
    'source repository' => ->(pr) { pr[:head][:repo][:id] = 99 },
    'deleted fork' => ->(pr) { pr[:head][:repo] = nil },
    'base repository' => ->(pr) { pr[:base][:repo][:id] = 2 },
    'closed state' => ->(pr) { pr[:state] = 'closed' }
  }.each do |name, change|
    it "rejects a candidate with a mismatched #{name}" do
      change.call(fixture.fetch(:pulls).first)
      expect_rejection
    end

    it "rechecks #{name} when fetching the independently resolved PR" do
      change.call(fixture.fetch(:pr))
      result = expect_rejection

      expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(%w[listPulls getPull])
    end
  end

  it 'rejects no matching open PR' do
    expect_rejection(pulls: [])
  end

  it 'does not let the wildcard bypass the caller repository boundary' do
    fixture[:inputs]['base-branch'] = '*'
    fixture[:pr][:base][:repo][:id] = 2

    expect_rejection
  end

  [nil, ''].each do |base|
    it "rejects a missing live base #{base.inspect} even with a wildcard" do
      fixture[:inputs]['base-branch'] = '*'
      fixture[:pr][:base][:ref] = base

      expect_rejection
    end
  end

  it 'rechecks the fetched PR number before comment access' do
    fixture[:pr][:number] = 8

    expect_rejection
  end

  [nil, '', 'not-a-date', '2026-11-15T10:00:01Z'].each do |created_at|
    it "rejects a PR with missing, invalid, or newer creation time #{created_at.inspect}" do
      pr[:created_at] = created_at

      expect_rejection
    end
  end

  it 'accepts creation timestamps equal to the run timestamp' do
    pr[:created_at] = run[:created_at]

    expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'uses the original run creation time rather than a newer rerun start time' do
    run[:run_started_at] = '2026-11-15T11:00:00Z'
    pr[:created_at] = '2026-11-15T10:30:00Z'

    expect_rejection
  end

  [nil, '', '42', 0].each do |repository_id|
    it "rejects invalid caller repository ID #{repository_id.inspect}" do
      fixture[:context][:payload][:repository][:id] = repository_id

      expect(expect_rejection.fetch('calls')).to be_empty
    end
  end

  it 'fails closed without a default or configured base' do
    fixture[:context][:payload][:repository][:default_branch] = ''

    expect(expect_rejection.fetch('calls')).to be_empty
  end

  %w[listPulls getPull].each do |method|
    it "fails closed if #{method} is inaccessible" do
      expect_rejection(apiError: method)
    end
  end

  it 'accepts a retargeted same-head PR when the wildcard permits its new current base' do
    fixture[:inputs]['base-branch'] = '*'
    fixture[:pulls].first[:base][:ref] = 'feature/lower'

    expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'rechecks a literal base restriction after lookup' do
    fixture[:pr][:base][:ref] = 'release'

    expect_rejection
  end

  it 'can route to a preexisting same-head PR that becomes unique after the original closes' do
    run[:pull_requests] = [{ number: 7 }]
    fixture[:pulls].first[:number] = fixture[:pr][:number] = 8
    result = execute_workflow(report: { pr_number: 8 })

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').last).to include('method' => 'createComment', 'issue_number' => 8)
  end

  %w[push workflow_dispatch].each do |event|
    it "skips #{event} runs" do
      run[:event] = event
      result = execute_workflow

      expect(result.fetch('skipped')).to be true
      expect(result.fetch('calls')).to be_empty
    end
  end

  %w[cancelled skipped timed_out action_required].each do |conclusion|
    it "skips #{conclusion} conclusions" do
      run[:conclusion] = conclusion
      result = execute_workflow

      expect(result.fetch('skipped')).to be true
      expect(result.fetch('calls')).to be_empty
    end
  end

  it 'skips callers without a workflow_run event' do
    fixture[:context][:eventName] = 'workflow_dispatch'
    fixture[:context][:payload].delete(:workflow_run)
    result = execute_workflow

    expect(result.fetch('skipped')).to be true
    expect(result.fetch('calls')).to be_empty
  end
end
