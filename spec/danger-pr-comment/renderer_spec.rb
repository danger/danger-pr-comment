# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DangerPrComment::Renderer do
  it 'renders all report sections while preserving Markdown' do
    report = {
      'errors' => ['Fix the build', 'Add tests'],
      'warnings' => ['Update documentation'],
      'messages' => ['Ready for review'],
      'markdowns' => ["**Details**\n\nRaw Markdown.", '[More information](https://example.test)']
    }

    expect(described_class.new(report).render).to eq(<<~MARKDOWN)
      ### Errors
      - Fix the build
      - Add tests

      ### Warnings
      - Update documentation

      ### Messages
      - Ready for review

      ### Markdowns
      **Details**

      Raw Markdown.

      [More information](https://example.test)
    MARKDOWN
  end

  it 'renders an all-clear report when sections are empty or omitted' do
    expect(described_class.new({ 'errors' => [], 'warnings' => nil }).render).to eq("No issues found.\n")
  end
end
