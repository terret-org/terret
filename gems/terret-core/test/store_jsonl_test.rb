# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/terret"
require_relative "store_contract"

class JSONLStoreTest < Minitest::Test
  include StoreContract

  def build_store
    store = Terret::Store::JSONL.new(dir: File.join(Dir.mktmpdir("terret-jsonl"), "sessions"))
    store.start(nil)
    store
  end

  def test_a_fresh_instance_reads_what_another_wrote
    dir = File.join(Dir.mktmpdir("terret-jsonl"), "sessions")
    writer = Terret::Store::JSONL.new(dir: dir)
    writer.start(nil)
    writer.append(contract_event("s1", 0))

    reader = Terret::Store::JSONL.new(dir: dir)
    reader.start(nil)
    assert_equal writer.read("s1"), reader.read("s1")
    assert_equal ["s1"], reader.session_ids
  end

  def test_a_torn_trailing_line_loses_itself_not_the_session
    dir = File.join(Dir.mktmpdir("terret-jsonl"), "sessions")
    store = Terret::Store::JSONL.new(dir: dir)
    store.start(nil)
    store.append(contract_event("s1", 0))
    store.append(contract_event("s1", 1))
    File.open(File.join(dir, "s1.jsonl"), "a") { |f| f.write('{"id":"torn","se') } # crash mid-write

    assert_equal [0, 1], store.read("s1").map(&:seq)
  end
end
