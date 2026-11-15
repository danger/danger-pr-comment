# frozen_string_literal: true

require 'json'
require 'danger-pr-comment/renderer'

module DangerPrComment
  class CLI
    USAGE = 'Usage: danger-pr-comment render REPORT.json'

    def self.run(argv, out: $stdout, err: $stderr)
      return usage(out) if [%w[-h], %w[--help]].include?(argv)

      render(argv, out, err)
    end

    def self.render(argv, out, err)
      return usage(err, 1) unless argv.length == 2 && argv.first == 'render'

      out.write(Renderer.new(JSON.parse(File.read(argv.last))).render)
      0
    rescue JSON::ParserError, ArgumentError, SystemCallError => e
      err.puts("danger-pr-comment: #{e.message}")
      1
    end
    private_class_method :render

    def self.usage(out, status = 0)
      out.puts(USAGE)
      status
    end
    private_class_method :usage
  end
end
