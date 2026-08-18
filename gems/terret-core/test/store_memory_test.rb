# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/terret"
require_relative "store_contract"

class MemoryStoreTest < Minitest::Test
  include StoreContract

  def build_store
    store = Terret::Store::Memory.new
    store.start(nil)
    store
  end
end
