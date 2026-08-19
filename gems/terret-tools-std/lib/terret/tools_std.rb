# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../terret-core/lib/terret" # monorepo path source
end

require_relative "tools_std/files"
require_relative "tools_std/bash"
require_relative "tools_std/terminals"
require_relative "tools_std/web_fetch"
require_relative "tools_std/task"
