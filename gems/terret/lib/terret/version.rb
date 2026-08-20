# frozen_string_literal: true

module Terret
  # The meta-gem's own version — what `trt --version` prints and what
  # terret.gemspec reads, so the number lives in exactly one place.
  #
  # Deliberately NOT Terret::VERSION: terret-core already owns that constant
  # and it is terret-core's number. The 0.1.0 lockstep release aligns the two
  # numbers, but they stay distinct constants — quietly redefining a sibling
  # gem's version constant is not a thing this gem gets to do.
  module Meta
    VERSION = "0.1.0"
  end
end
