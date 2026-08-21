# frozen_string_literal: true

# Hames is Terret's plugin kernel: services in a context, typed events with
# four dispatch modes, reversible effects, and dependency-driven boot. It has
# no knowledge of LLMs and is reusable for any plugin-composed application.
module Hames
  VERSION = "0.1.1"
end

require_relative "hames/events"
require_relative "hames/context"
require_relative "hames/schema"
require_relative "hames/loader"
