# frozen_string_literal: true

module Terret
  # The meta-gem's own version — what `trt --version` prints and what
  # terret.gemspec reads, so the number lives in exactly one place.
  #
  # Deliberately NOT Terret::VERSION: terret-core already owns that constant
  # and it is terret-core's number. The two are not on the same version until
  # the lockstep release, and quietly redefining a sibling gem's version
  # constant is not a thing this gem gets to do.
  module Meta
    VERSION = "0.0.2"
  end
end
