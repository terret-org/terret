# frozen_string_literal: true

begin
  require "hames"
rescue LoadError
  require_relative "../../hames/lib/hames" # monorepo path source
end

module Terret
  VERSION = "0.1.0"

  # Event vocabulary. Durable events land in the session log; the rest are
  # live extension points. Modes are the public contract (see docs/events.md).
  def self.declare_events!
    e = ->(name, mode, durable: false, doc: nil) {
      Hames.event(name, mode:, durable:, doc:)
    }
    # durable session events
    e.("session/created",   :emit, durable: true, doc: "session opened")
    e.("session/forked",    :emit, durable: true, doc: "lineage record")
    e.("turn/start",        :emit, durable: true, doc: "turn opened")
    e.("turn/end",          :emit, durable: true, doc: "turn closed with status")
    e.("step/start",        :emit, durable: true, doc: "model step opened")
    e.("step/end",          :emit, durable: true, doc: "model step closed")
    e.("user/message",      :emit, durable: true, doc: "entered user input")
    e.("assistant/chunk",   :emit, durable: true, doc: "raw stream delta (replay/UI fidelity)")
    e.("assistant/message", :emit, durable: true, doc: "completed assistant message")
    e.("tool/call",         :emit, durable: true, doc: "tool invocation requested by model")
    e.("tool/result",       :emit, durable: true, doc: "tool outcome")
    e.("context/injected",  :emit, durable: true, doc: "agent.inject landed in a request")
    e.("session/compacted", :emit, durable: true,
       doc: "history up to upto_seq replaced by summary (still model-visible)")
    e.("approval/requested", :emit, durable: true, doc: "tool call parked awaiting a decision")
    e.("approval/resolved",  :emit, durable: true, doc: "parked call decided (approve/deny)")
    # live extension points
    e.("session/event",     :emit,      doc: "fan-out of every durable append")
    e.("agent/pre_step",    :waterfall, doc: "rewrite or reject the claimed messages")
    e.("agent/request",     :waterfall, doc: "rewrite the outbound model request")
    e.("llm/stream",        :waterfall, doc: "wrap/replace the adapter stream")
    e.("tools/pre_execute",  :waterfall, doc: "validate, veto, or rewrite a call")
    e.("tools/execute",      :waterfall, doc: "a provider may replace execution")
    e.("tools/post_execute", :waterfall, doc: "truncate/redact the result")
    e.("agent/turn_stopping", :serial,   doc: "ordered veto point before turn/end")
  end
end

require_relative "terret/llm"
require_relative "terret/store"
require_relative "terret/sessions"
require_relative "terret/tools"
require_relative "terret/loop"

Terret.declare_events!
