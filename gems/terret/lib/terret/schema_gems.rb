# frozen_string_literal: true

module Terret
  # Every gem whose services declare a Hames::Schema, as require paths. This is
  # the single source `rake config:catalog` and the schema tests both read, so a
  # newly configurable gem is added in one place. Split across two lists, a gem
  # added to only one would be silently absent from the catalog with CI green.
  #
  # It is the base bundle's own requires plus the interface/adapter gems that
  # ship schemas but are not part of terret-base (ws, mcp, morph).
  SCHEMA_GEMS = %w[
    terret/store/sqlite
    terret/openrouter
    terret/exec
    terret/tools_std
    terret/sandbox/docker
    terret/ws
    terret/mcp
    terret/morph
  ].freeze
end
