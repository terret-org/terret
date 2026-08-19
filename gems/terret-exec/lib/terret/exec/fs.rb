# frozen_string_literal: true

require "fileutils"

module Terret
  module Exec
    # Deny-by-default: a path outside every granted workspace directory —
    # including one reached only by resolving a `../` traversal or following a
    # symlink — is Denied rather than silently clamped or allowed through. An
    # `fs/authorize` veto renders the same way, so from the caller's side a
    # containment failure and a policy veto look identical: neither was
    # admitted, and the reason is all that differs.
    Denied = Class.new(Terret::Tools::Failure)

    # #edit was asked to replace a string that doesn't appear exactly once.
    # Guessing which occurrence was meant is worse than refusing outright: an
    # ambiguous edit is a bug in the caller's plan, not something to resolve
    # by picking the first match.
    EditAmbiguous = Class.new(Terret::Tools::Failure)

    # ctx[:fs] — workspace-contained file ops (plan §6.6; docs/exec.md §2-3).
    # Every path is realpath-contained to the granted `workspace:` list before
    # any syscall runs (see #contain), then the op dispatches through the
    # `fs/authorize` waterfall so a plugin can veto an otherwise-contained
    # call. Containment is realpath-based rather than string-based
    # specifically so both a `../` traversal and a symlink planted inside the
    # workspace that points outside it resolve to where they actually land
    # before the check runs, rather than being caught (or missed) as strings.
    class FS < Hames::Service
      service_key :fs

      def start(ctx)
        @ctx = ctx
        @workspace = resolve_workspace(config[:workspace])
      end

      def reconfigure(config)
        @workspace = resolve_workspace(config[:workspace])
      end

      def read(path) = File.read(authorize!(:read, path))

      def write(path, content)
        p = authorize!(:write, path)
        FileUtils.mkdir_p(File.dirname(p))
        File.write(p, content)
        p
      end

      def edit(path, old, new)
        p = authorize!(:write, path)
        body = File.read(p)
        # #scan with a String argument (not a Regexp) matches literally, so
        # `old` is never interpreted as a regex source here.
        count = body.scan(old).length
        raise EditAmbiguous, "#{old.inspect} appears #{count} times in #{path}; must be exactly 1" unless count == 1

        File.write(p, body.sub(old, new))
        p
      end

      def stat(path)
        p = authorize!(:read, path)
        s = File.stat(p)
        { size: s.size, mtime: s.mtime.utc.iso8601, directory: s.directory? }
      end

      # Pattern is joined against every granted root in turn. A match is kept
      # only if realpath-ing it (following whatever symlink the glob turned
      # up) still lands inside the workspace, so a symlinked entry can never
      # leak an outside path through the listing.
      def glob(pattern)
        @workspace.flat_map { |root| Dir.glob(File.join(root, pattern)) }
                  .select { |p| contained?(File.realpath(p)) }
      end

      private

      # A granted root must itself already exist, and is realpath'd up front
      # for the same reason every op's target is: on macOS in particular,
      # `Dir.mktmpdir` hands back a path under `/var`, itself a symlink to
      # `/private/var`, and #contain always realpaths its resolved result —
      # comparing that against an un-realpath'd root would fail containment
      # for every path inside a workspace whose own name involves a symlink.
      def resolve_workspace(dirs)
        Array(dirs).map { |d| File.realpath(File.expand_path(d)) }
      end

      def authorize!(op, path)
        resolved = contain(path)
        admitted = @ctx.waterfall("fs/authorize", { op:, path: resolved })
        raise Denied, admitted.reason if admitted.is_a?(Terret::Tools::Veto)

        admitted.is_a?(Hash) ? (admitted[:path] || resolved) : resolved
      end

      # Expand, then realpath the DEEPEST EXISTING prefix (the target itself
      # may not exist yet — #write's whole point) and re-join whatever tail
      # doesn't exist yet. Because the deepest existing prefix is realpath'd
      # first, a `../` segment or a symlink anywhere in that prefix resolves
      # to its real target before containment is ever checked.
      def contain(path)
        expanded = File.expand_path(path.to_s)
        deepest = expanded
        deepest = File.dirname(deepest) until File.exist?(deepest)
        real_deepest = File.realpath(deepest)
        tail = expanded[deepest.length..]
        resolved = tail.nil? || tail.empty? ? real_deepest : File.join(real_deepest, tail)
        raise Denied, "#{path} is outside the granted workspace" unless contained?(resolved)

        resolved
      end

      # Prefix match with a trailing-separator guard: a workspace granted at
      # `/ws` must admit `/ws` itself and anything under `/ws/`, but never
      # `/ws-evil` — a bare `start_with?(root)` would let that sibling through.
      def contained?(resolved)
        @workspace.any? { |root| resolved == root || resolved.start_with?("#{root}/") }
      end
    end
  end
end
