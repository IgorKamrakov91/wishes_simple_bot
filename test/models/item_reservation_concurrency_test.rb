require "test_helper"
require "timeout"

class ItemReservationConcurrencyTest < ActiveSupport::TestCase
  # The two requests must use independent, committed database connections.
  self.use_transactional_tests = false

  setup do
    @owner = User.create!(telegram_id: 42001, first_name: "Owner")
    @guests = [ 42002, 42003 ].map { |id| User.create!(telegram_id: id, first_name: "Guest") }
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @item = @wishlist.items.create!(title: "Puzzle")
  end

  teardown do
    @owner&.destroy!
    @guests&.each(&:destroy!)
  end

  test "two guests booking the same snapshot have exactly one winner" do
    ready = Queue.new
    start = Queue.new
    requests = @guests.map do |guest|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          item = Item.find(@item.id)
          ready << true
          start.pop
          [ guest.telegram_id, item.reserve_for!(guest, expected_version: 0) ]
        end
      end
    end

    results = Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { start << true }
      requests.map(&:value)
    end

    winners = results.select { |_, changed| changed }
    assert_equal 1, winners.size
    assert_equal winners.first.first, @item.reload.reserved_by
    assert_equal 1, @item.reservation_version
  ensure
    requests&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end
end
