# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'yaml'

RSpec.describe 'Empty report comments' do
  let(:workflow) { YAML.load_file(File.expand_path('../../.github/workflows/danger-comment.yml', __dir__)) }
  let(:inputs) do
    workflow.fetch('on', workflow[true]).fetch('workflow_call').fetch('inputs')
            .transform_values { |input| input.fetch('default', '') }
  end
  let(:fixture) do
    step = workflow.fetch('jobs').fetch('comment').fetch('steps').last
    {
      script: step.fetch('with').fetch('script'),
      environment: step.fetch('env').transform_values do |template|
        template.gsub(/\$\{\{\s*inputs\.([\w-]+)\s*\}\}/) { inputs.fetch(Regexp.last_match(1)).to_s }
      end,
      context: {
        repo: { owner: 'danger', repo: 'example' },
        serverUrl: 'https://github.com',
        payload: { workflow_run: { id: 123 } }
      },
      report: { pr_number: 7, errors: [], warnings: [], messages: [], markdowns: [] },
      comments: []
    }
  end

  def execute_workflow(**overrides)
    harness = File.expand_path('../fixtures/run_empty_comment_workflow.js', __dir__)
    stdout, stderr, status = Open3.capture3('node', harness, stdin_data: JSON.generate(fixture.merge(overrides)))
    raise "Node workflow harness failed: #{stderr}" unless status.success?

    result = JSON.parse(stdout)
    expect(result.fetch('failures')).to be_empty
    result.fetch('calls')
  end

  it 'creates an empty report comment by default' do
    calls = execute_workflow

    expect(calls.last).to include('method' => 'createComment', 'issue_number' => 7)
    expect(calls.last.fetch('body')).to include('No issues found')
  end

  it 'does not create an empty report comment when disabled' do
    inputs['comment-empty'] = false

    expect(execute_workflow.map { |call| call.fetch('method') }).to eq(['listComments'])
  end

  it 'treats omitted report sections as empty' do
    inputs['comment-empty'] = false

    expect(execute_workflow(report: { pr_number: 7 }).map { |call| call.fetch('method') }).to eq(['listComments'])
  end

  it 'clears an existing report comment even when empty comments are disabled' do
    inputs['comment-empty'] = false
    calls = execute_workflow(comments: [{
                               id: 10,
                               user: { login: 'github-actions[bot]', type: 'Bot' },
                               body: "<!-- danger-report -->\nOld warnings"
                             }])

    expect(calls.last).to include('method' => 'updateComment', 'comment_id' => 10)
    expect(calls.last.fetch('body')).to include('No issues found')
    expect(calls.last.fetch('body')).not_to include('Old warnings')
  end

  ['', " \n\t", "No issues found.\n"].each do |markdown|
    it "suppresses a new comment for empty Markdown #{markdown.inspect} despite findings in the arrays" do
      inputs['comment-empty'] = false
      fixture[:report][:warnings] = ['Ignored by override']
      fixture[:report][:rendered_markdown] = markdown

      expect(execute_workflow.map { |call| call.fetch('method') }).to eq(['listComments'])
    end
  end

  it 'clears an existing comment when a blank override hides legacy findings' do
    inputs['comment-empty'] = false
    fixture[:report][:warnings] = ['Ignored by override']
    fixture[:report][:rendered_markdown] = ''
    calls = execute_workflow(comments: [{
                               id: 10,
                               user: { login: 'github-actions[bot]', type: 'Bot' },
                               body: "<!-- danger-report -->\nOld warnings"
                             }])

    expect(calls.last).to include('method' => 'updateComment', 'comment_id' => 10)
    expect(calls.last.fetch('body')).to include("No issues found.\n\n[View run]")
    expect(calls.last.fetch('body')).not_to include('Ignored by override', 'Old warnings')
  end

  %i[errors warnings messages markdowns].each do |section|
    it "still comments on #{section} when empty comments are disabled" do
      inputs['comment-empty'] = false
      fixture[:report][section] = ['A finding']
      calls = execute_workflow

      expect(calls.last).to include('method' => 'createComment', 'issue_number' => 7)
      expect(calls.last.fetch('body')).to include('A finding')
    end
  end
end
