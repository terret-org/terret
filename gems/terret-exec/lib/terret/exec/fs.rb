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
    # call. A listener may veto or let the call proceed; it can never redirect
    # the syscall to a different path (see #authorize!). Containment is
    # realpath-based rather than string-based specifically so both a `../`
    # traversal and a symlink planted inside the workspace that points
    # outside it resolve to where they actually land before the check runs,
    # rather than being caught (or missed) as strings.
    class FS < Hames::Service
      service_key :fs
      config_schema workspace: { type: [String, Array],
                                 doc: "directory root(s) every fs op is contained to; " \
                                      "empty or unset denies every operation" }

      def start(ctx)
        @ctx = ctx
        @workspace = resolve_workspace(config[:workspace])
      end

      def reconfigure(config)
        @workspace = resolve_workspace(config[:workspace])
      end

      def read(path) = read_contained(authorize!(:read, path))

      def write(path, content)
        p = authorize!(:write, path)
        FileUtils.mkdir_p(File.dirname(p))
        write_contained(p, content)
        p
      end

      def edit(path, old, new)
        p = authorize!(:write, path)
        body = read_contained(p)
        # #scan with a String argument (not a Regexp) matches literally, so
        # `old` is never interpreted as a regex source here.
        count = body.scan(old).length
        raise EditAmbiguous, "#{old.inspect} appears #{count} times in #{path}; must be exactly 1" unless count == 1

        write_contained(p, body.sub(old, new))
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

      # The waterfall's only power is to veto: a returned Veto raises Denied.
      # A listener that chains with `next_.(call.merge(path: ...))` may hand
      # back a Hash with a rewritten `:path`, but that rewrite is deliberately
      # ignored — #contain already proved `resolved` sits inside the granted
      # workspace, and honoring a listener's path would let it redirect the
      # syscall anywhere on disk. The containment decision is never delegated
      # to a listener.
      def authorize!(op, path)
        resolved = contain(path)
        admitted = @ctx.waterfall("fs/authorize", { op:, path: resolved })
        raise Denied, admitted.reason if admitted.is_a?(Terret::Tools::Veto)

        resolved
      end

      # Resolve to where the syscall would ACTUALLY land, then containment-check
      # that. The target itself may not exist yet (#write's whole point), so we
      # can't blindly realpath it; instead #resolve_real walks up to the deepest
      # prefix that exists OR is a symlink. A `../` segment or an already-real
      # symlink in an existing prefix is followed by realpath; a DANGLING
      # symlink — one File.exist? reports as absent because it follows the link
      # to a missing target — is resolved to where it points instead of being
      # waved through as a fresh path (the container-escape the earlier check
      # missed, since the later File.write would follow it outside).
      def contain(path)
        resolved = resolve_real(File.expand_path(path.to_s))
        raise Denied, "#{path} is outside the granted workspace" unless contained?(resolved)

        resolved
      end

      # The kernel gives up on a symlink chain at MAXSYMLINKS and answers ELOOP;
      # this does the same. A LOOP (a -> b -> a) is a dangling chain that never
      # terminates, so unbounded recursion here would blow the stack — and
      # SystemStackError is not a StandardError, so it escapes Registry#execute's
      # and Loop#guarded_call's rescues and kills the whole turn rather than
      # failing closed. Capping the hops turns it into an ordinary Denied.
      MAX_SYMLINK_HOPS = 40

      def resolve_real(expanded, hops = 0)
        if hops > MAX_SYMLINK_HOPS
          raise Denied, "#{expanded} resolves through more than #{MAX_SYMLINK_HOPS} symlinks " \
                        "(a loop, or a chain too long to follow)"
        end

        deepest = expanded
        deepest = File.dirname(deepest) until File.exist?(deepest) || File.symlink?(deepest)
        tail = expanded[deepest.length..]
        base =
          if File.symlink?(deepest) && !File.exist?(deepest)
            # Dangling symlink: resolve one hop to where it points (relative
            # targets against the link's real directory), then keep resolving
            # since the target may itself dangle, be relative, or be symlinked.
            resolve_real(File.expand_path(File.readlink(deepest), File.realpath(File.dirname(deepest))), hops + 1)
          else
            File.realpath(deepest)
          end
        tail.nil? || tail.empty? ? base : File.join(base, tail)
      end

      # Read/write the final syscall with File::NOFOLLOW so a symlink swapped in
      # at the leaf between #contain and here refuses at open rather than being
      # followed. #resolve_real never returns a symlink as the final component
      # (an existing target is realpath'd; a dangling one is resolved to where
      # it points), so a legitimate regular file always opens cleanly. This
      # guards only the leaf; intermediate components remain a small accepted
      # TOCTOU window.
      def read_contained(path) = File.open(path, File::RDONLY | File::NOFOLLOW, &:read)

      def write_contained(path, content)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW) { |f| f.write(content) }
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
