# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../terret-core/lib/terret" # monorepo path source
end

require_relative "acp/wire"
