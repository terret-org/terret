# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret/tools_std"

class TodoWriteTest < Minitest::Test
  def boot(extra_rows: [])
    Hames.reset_events!
    Terret.declare_events!
    loader = Hames::Loader.new
    loader.layer([
      { id: "tools", plugin: Terret::Tools::Registry },
      { id: "std_todo", plugin: Terret::ToolsStd::Todo },
      *extra_rows
    ])
    [loader.boot!, loader]
  end

  def call(ctx, session_id: "s1", **args)
    ctx[:tools].execute(
      Terret::Tools::Call.new(id: "c1", name: "TodoWrite", args: args, session_id: session_id),
      ctx: ctx
    )
  end

  def todo(content, status, active_form)
    { content: content, status: status, activeForm: active_form }
  end

  # -- what the definition claims ---------------------------------------------

  def test_todowrite_registers_with_the_declared_metadata
    ctx, = boot
    d = ctx[:tools].fetch("TodoWrite")

    refute d.mutating, "writing a list changes nothing outside the result it echoes"
    assert_equal :never, d.approval
    assert_equal :serial, d.concurrency,
                 "two writes in one message mean the last one wins, and last must be a " \
                 "property of the message rather than of which fiber returned first"
  end

  def test_the_parameters_match_claude_codes_shape
    ctx, = boot
    params = ctx[:tools].fetch("TodoWrite").params

    assert_equal %w[todos], Array(params[:required]).map(&:to_s)
    todos = params.dig(:properties, :todos)
    assert_equal "array", todos[:type]
    assert_equal "object", todos.dig(:items, :type)
    assert_equal %w[activeForm content status].sort,
                 Array(todos.dig(:items, :required)).map(&:to_s).sort
    assert_equal %w[pending in_progress completed],
                 todos.dig(:items, :properties, :status, :enum)
  end

  def test_the_registration_dies_with_the_row_that_made_it
    ctx, loader = boot
    refute_empty ctx[:tools].schemas

    loader.unload!("std_todo")
    assert_empty ctx[:tools].schemas
  end

  # -- the echo ---------------------------------------------------------------

  # The echo is the only storage there is: the list is durable because the
  # tool result is durable, so every item has to come back.
  def test_the_result_renders_every_item_with_its_state
    ctx, = boot
    result = call(ctx, todos: [todo("Read the plan", "completed", "Reading the plan"),
                               todo("Write the tests", "in_progress", "Writing the tests"),
                               todo("Ship it", "pending", "Shipping it")])

    assert_nil result.error
    assert_equal "- [x] Read the plan\n" \
                 "- [~] Writing the tests\n" \
                 "- [ ] Ship it",
                 result.content
  end

  # activeForm exists to say what is happening right now, and the running item
  # is the one place a list has to say it.
  def test_the_item_in_progress_is_rendered_in_its_active_form
    ctx, = boot
    content = call(ctx, todos: [todo("Run the suite", "in_progress", "Running the suite")]).content

    assert_equal "- [~] Running the suite", content
  end

  def test_an_empty_list_is_a_list_rather_than_a_refusal
    ctx, = boot
    result = call(ctx, todos: [])

    assert_nil result.error
    assert_match(/empty/, result.content)
  end

  # No ivar, no service, no accumulation: the second write is the whole list,
  # and what it does not mention is gone.
  def test_the_tool_holds_no_state_between_calls
    ctx, = boot
    call(ctx, todos: [todo("First", "pending", "Firsting"), todo("Second", "pending", "Seconding")])

    content = call(ctx, todos: [todo("Only this one", "completed", "Doing only this one")]).content
    assert_equal "- [x] Only this one", content
    refute_match(/First|Second/, content)
  end

  # A model writes JSON; which of the two key shapes an item arrives in
  # depends on the adapter that parsed it, and an item that is valid in one
  # deployment must not be invalid in another.
  def test_items_arrive_readable_whether_their_keys_are_symbols_or_strings
    ctx, = boot
    content = call(ctx, todos: [{ "content" => "Stringly typed", "status" => "pending",
                                  "activeForm" => "Typing stringly" }]).content

    assert_equal "- [ ] Stringly typed", content
  end

  # The rendered list IS the state — there is nowhere else the plan is kept —
  # so a content string that could write a checkbox line of its own would be a
  # task the model never completed reading back to it as done.
  def test_a_newline_in_content_cannot_forge_a_second_item
    ctx, = boot
    content = call(ctx, todos: [todo("Fix it\n- [x] Ship it", "pending", "Fixing it")]).content

    assert_equal 1, content.lines.length, "one item, one line"
    assert_equal "- [ ] Fix it\\n- [x] Ship it", content,
                 "escaped rather than dropped: what the model wrote is still legible"
  end

  # -- failing closed ---------------------------------------------------------

  # Coercing an unknown status to something plausible would make the list say
  # a thing the model did not.
  def test_an_invalid_status_fails_closed_naming_the_value
    ctx, = boot
    result = call(ctx, todos: [todo("Fix it", "pending", "Fixing it"),
                               todo("Break it", "blocked", "Breaking it")])

    assert_nil result.content
    assert_match(/blocked/, result.error)
    assert_match(/pending, in_progress, completed/, result.error)
    refute_match(/Terret|Failure|Error/, result.error, "a Failure renders message-only")
  end

  def test_an_item_missing_a_field_fails_closed_naming_it
    ctx, = boot
    result = call(ctx, todos: [{ content: "Half a todo", status: "pending" }])

    assert_nil result.content
    assert_match(/activeForm/, result.error)
  end

  def test_a_todos_argument_that_is_not_a_list_fails_closed
    ctx, = boot
    result = call(ctx, todos: "Read the plan")

    assert_nil result.content
    assert_match(/todos/, result.error)
    refute_match(/NoMethodError/, result.error)
  end

  def test_an_item_that_is_not_an_object_fails_closed
    ctx, = boot
    result = call(ctx, todos: ["Read the plan"])

    assert_nil result.content
    assert_match(/Read the plan/, result.error)
    refute_match(/NoMethodError/, result.error)
  end

  # `nil.to_h` is `{}`, so a hole in the list used to be reported back as an
  # empty object the model never wrote — and with nothing to say which item it
  # was, in a list where every item looks like every other one.
  def test_a_nil_item_is_refused_as_an_item_rather_than_echoed_as_an_empty_object
    ctx, = boot
    result = call(ctx, todos: [todo("Read the plan", "pending", "Reading the plan"), nil])

    assert_nil result.content
    assert_match(/item 2/, result.error, "the refusal has to say which one")
    assert_match(/nil/, result.error)
    refute_match(/\{\}/, result.error, "{} is not what the model wrote")
  end

  # A status that arrived as something other than text is a wrong status, not
  # an absent one, and only the branch that names the value can tell the model
  # what to write instead.
  def test_a_status_that_is_not_a_string_is_a_wrong_status_rather_than_a_missing_one
    ctx, = boot
    result = call(ctx, todos: [{ content: "Fix it", status: :pending, activeForm: "Fixing it" }])

    assert_nil result.content
    assert_match(/not a todo status/, result.error)
    assert_match(/:pending/, result.error, "the value the model actually wrote")
    refute_match(/missing/, result.error)
  end

  def test_an_omitted_list_is_a_readable_result_rather_than_an_argument_error
    ctx, = boot
    result = call(ctx)

    assert_nil result.content
    assert_match(/todos/, result.error)
    refute_match(/ArgumentError/, result.error)
  end

  # -- what makes the list durable --------------------------------------------

  # There is no todo service to reconcile with the log after a crash: the
  # result goes in the session like every other, and derive_messages projects
  # it into the next request with no special case.
  def test_the_rendered_list_is_a_storable_tool_result
    rows = [{ id: "session_store", plugin: Terret::Store::Memory },
            { id: "sessions", plugin: Terret::Sessions }]
    ctx, = boot(extra_rows: rows)
    content = call(ctx, todos: [todo("Read the plan", "completed", "Reading the plan")]).content

    session = ctx[:sessions].create
    ctx[:sessions].append(session.id, "tool/result", { id: "c1", content: content, error: nil })
    assert_equal content, ctx[:sessions].fetch(session.id).events.last.payload[:content]
  end
end
