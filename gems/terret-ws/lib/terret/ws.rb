# frozen_string_literal: true

begin
  require "terret"
rescue LoadError
  require_relative "../../../terret-core/lib/terret" # monorepo path source
end

require_relative "ws/frames"
require_relative "ws/bounded_queue"
require_relative "ws/connection"
require_relative "ws/service"
