# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'yaml'

RSpec.describe 'Sticky comment workflow' do
  let(:bot) { { login: 'github-actions[bot]', type: 'Bot' } }
  let(:marker) { '<!-- danger-report -->' }
  let(:fixture) do
    workflow = YAML.load_file(File.expand_path('../../.github/workflows/danger-comment.yml', __dir__))
    job = workflow.fetch('jobs').fetch('comment')
    step = job.fetch('steps').last
    {
      script: step.fetch('with').fetch('script'),
      environment: step.fetch('env'),
      concurrency: job.fetch('concurrency'),
      context: {
        repo: { owner: 'danger', repo: 'example' },
        serverUrl: 'https://github.com',
        payload: {
          repository: { default_branch: 'main' },
          workflow_run: { id: 123, head_repository: { id: 42 }, head_branch: 'contribution', head_sha: 'abc123' }
        }
      },
      inputs: workflow.fetch('on', workflow[true]).fetch('workflow_call').fetch('inputs')
                      .transform_values { |input| input.fetch('default', '') },
      report: { pr_number: 7, warnings: ['Please add tests'] },
      comments: []
    }
  end

  def execute_workflow(**overrides)
    harness = File.expand_path('../fixtures/run_sticky_comment_workflow.js', __dir__)
    stdout, stderr, status = Open3.capture3('node', harness, stdin_data: JSON.generate(fixture.merge(overrides)))
    raise "Node workflow harness failed: #{stderr}" unless status.success?

    result = JSON.parse(stdout)
    expect(result.fetch('failures')).to be_empty
    result
  end

  it 'creates a report comment when no matching bot comment exists' do
    result = execute_workflow

    expect(result.fetch('calls').last).to include('method' => 'createComment', 'issue_number' => 7)
    expect(result.fetch('comments').last.fetch('body')).to start_with("#{marker}\n")
  end

  it 'updates the existing Actions bot report rather than creating a duplicate' do
    result = execute_workflow(comments: [
                                { id: 9, user: { login: 'contributor', type: 'User' }, body: "#{marker}\nDiscussion" },
                                { id: 10, user: bot, body: "#{marker}\nOld report" }
                              ])

    expect(result.fetch('calls').last).to include('method' => 'updateComment', 'comment_id' => 10)
    expect(result.fetch('comments').size).to eq(2)
    expect(result.fetch('comments').first.fetch('body')).to eq("#{marker}\nDiscussion")
  end

  it 'finds an existing report beyond the first page of comments' do
    comments = Array.new(100) { |index| { id: index, user: { login: 'contributor', type: 'User' }, body: 'Discussion' } }
    comments << { id: 101, user: bot, body: "#{marker}\nOld report" }
    result = execute_workflow(comments: comments)

    expect(result.fetch('calls').select { |call| call.fetch('method') == 'listComments' }.map { |call| call.fetch('page') }).to eq([1, 2])
    expect(result.fetch('calls').last).to include('method' => 'updateComment', 'comment_id' => 101)
    expect(result.fetch('comments').size).to eq(101)
  end

  {
    'a person' => { login: 'contributor', type: 'User' },
    'another bot' => { login: 'dependabot[bot]', type: 'Bot' },
    'an account without bot metadata' => { login: 'github-actions[bot]' },
    'a deleted account' => nil
  }.each do |author, user|
    it "does not update a matching marker posted by #{author}" do
      original_body = "#{marker}\nNot our report"
      result = execute_workflow(comments: [{ id: 10, user: user, body: original_body }])

      expect(result.fetch('calls').last).to include('method' => 'createComment')
      expect(result.fetch('comments').first.fetch('body')).to eq(original_body)
    end
  end

  ["Quoted marker:\n<!-- danger-report -->\n", '<!-- danger-report --> suffix', "<!-- other-report -->\n", nil].each do |body|
    it "does not update a bot comment with a nonmatching leading marker #{body.inspect}" do
      result = execute_workflow(comments: [{ id: 10, user: bot, body: body }])

      expect(result.fetch('calls').last).to include('method' => 'createComment')
      expect(result.fetch('comments').first.fetch('body')).to eq(body)
    end
  end

  it 'reuses a newly created comment on the next run' do
    first = execute_workflow
    second = execute_workflow(comments: first.fetch('comments'))

    expect(second.fetch('calls').last).to include('method' => 'updateComment', 'comment_id' => 1000)
    expect(second.fetch('comments').size).to eq(1)
  end

  it 'updates only the selected marker when multiple report comments exist' do
    result = execute_workflow(comments: [
                                { id: 10, user: bot, body: "<!-- other-report -->\nOther report" },
                                { id: 11, user: bot, body: "#{marker}\nSelected report" }
                              ])

    expect(result.fetch('calls').last).to include('method' => 'updateComment', 'comment_id' => 11)
    expect(result.fetch('comments').first.fetch('body')).to eq("<!-- other-report -->\nOther report")
  end

  it 'uses the same concurrency group across runs for the same PR source without cancelling its writer' do
    first = execute_workflow
    fixture[:context][:payload][:workflow_run][:id] = 456
    second = execute_workflow

    expect(first.fetch('concurrencyGroup')).to eq(second.fetch('concurrencyGroup'))
    expect(second.fetch('cancelInProgress')).to be false
  end

  it 'uses separate concurrency groups for different markers' do
    first = execute_workflow
    fixture[:inputs]['comment-marker'] = '<!-- another-report -->'
    second = execute_workflow

    expect(first.fetch('concurrencyGroup')).not_to eq(second.fetch('concurrencyGroup'))
  end

  it 'uses separate concurrency groups for fork branches with the same name' do
    first = execute_workflow
    fixture[:context][:payload][:workflow_run][:head_repository][:id] = 43
    second = execute_workflow

    expect(first.fetch('concurrencyGroup')).not_to eq(second.fetch('concurrencyGroup'))
  end
end
