# frozen_string_literal: true

module Terret
  module Exec
    # ctx[:sandbox] — the seam every argv passes through before it becomes a
    # real process (docs/exec.md §4). `None` is the identity provider: the
    # explicit, opt-in-only trusted mode (plan §13) — a profile that wants no
    # process isolation says so by mounting this row rather than by an
    # isolation feature silently failing open. The docker provider (plan §12)
    # replaces this plugin wholesale via a single patch row — the same
    # plugin-class swap the kernel work (Task 2) proved — so `wrap`'s
    # contract has to be small and honest: it does nothing here, and that
    # nothing is the point.
    class SandboxNone < Hames::Service
      service_key :sandbox

      def start(_ctx); end

      def wrap(argv, cwd:) = argv

      def isolated? = false

      def workspace_ready!; end
    end
  end
end
