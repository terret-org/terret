# frozen_string_literal: true

module Terret
  module MCP
    # Pure translation between MCP shapes and terret shapes (docs/mcp.md).
    # Duck-typed against manceps' value objects so it needs no manceps at
    # test time and no network ever.
    module Translate
      NAME_RE = /\A[a-z0-9_-]+\z/

      # A tool name comes from the server's tools/list — remote input, not the
      # operator's config — and is interpolated into the `mcp__server__name` tool
      # id and into every log line that names the call. A control-char or
      # whitespace name would poison both, so a tool is held to a safe identifier
      # charset before it is mounted (Service#sync_tools skips one that fails).
      # It is broader than the operator-chosen server NAME_RE on purpose — real
      # MCP tools are named in mixed case and sometimes carry dots — but it still
      # admits nothing that is not a plain, log-safe identifier character.
      TOOL_NAME_RE = /\A[A-Za-z0-9_.-]+\z/

      module_function

      def assert_server_name!(name)
        name = name.to_s
        raise ArgumentError, "server name must match #{NAME_RE.inspect}, got #{name.inspect}" unless name.match?(NAME_RE)

        name
      end

      def valid_tool_name?(name) = name.is_a?(String) && name.match?(TOOL_NAME_RE)

      def tool_name(server, tool) = "mcp__#{server}__#{tool}"

      # Keyword args for Registry#register. Remote tools default to
      # mutating: we cannot see their effects, so policy assumes the worst.
      def definition_args(server:, tool:, approval:)
        { name: tool_name(server, tool.name), description: tool.description.to_s,
          params: tool.input_schema || {}, mutating: true, approval: approval }
      end

      # structured_content wins (already primitives); else text items join,
      # binary/resource items degrade to a typed placeholder. nil for errors.
      def result_content(result)
        return nil if result.error?
        return result.structured_content if result.structured?

        result.content.map do |item|
          item.type == "text" ? item.text : "[#{item.type} #{item.uri || item.mime_type || item.type}]"
        end.join("\n")
      end

      def result_error(result)
        return nil unless result.error?

        text = result.text.to_s
        text.empty? ? "tool failed with no message" : text
      end
    end
  end
end
