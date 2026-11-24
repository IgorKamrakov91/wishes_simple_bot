require "test_helper"

class BotGuestListTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 97801)
    @guest = User.create!(telegram_id: 97802)
    @list = @owner.wishlists.create!(title: "Birthday")
  end

  test "budget ceilings use exact decimal prices and always include unpriced gifts" do
    prices = [ nil, "0.01", "999.99", "1000.00", "1000.01", "3000.00", "3000.01", "10000.00", "10000.01" ]
    gifts = prices.map.with_index { |price, index| @list.items.create!(title: "Gift #{index}", price: price) }
    expected = { "a" => gifts, "s" => gifts.first(4), "m" => gifts.first(6), "l" => gifts.first(8),
                 "h" => [ gifts.first, gifts.last ], "n" => [ gifts.first ] }

    expected.each do |budget, items|
      assert_equal items.map(&:id), Bot::GuestList.new(@list, budget: budget).items.map(&:id), budget
    end
  end

  test "unreserved gifts precede reservations with stable id order in each group" do
    taken = @list.items.create!(title: "Taken", reserved_by: @guest.telegram_id)
    free1 = @list.items.create!(title: "First free")
    mine = @list.items.create!(title: "Another taken", reserved_by: @guest.telegram_id)
    free2 = @list.items.create!(title: "Second free")

    assert_equal [ free1.id, free2.id, taken.id, mine.id ], Bot::GuestList.new(@list).items.map(&:id)
  end

  test "unknown filters safely fall back to all and callbacks fit Telegram's byte limit" do
    gift = @list.items.create!(title: "Gift", price: 9000)
    assert_equal [ gift.id ], Bot::GuestList.new(@list, budget: "invalid").items.map(&:id)
    huge_id = 9_223_372_036_854_775_807
    @list.id = huge_id
    selection = Bot::GuestList.new(@list, budget: "h")
    data = [ selection.page_callback(huge_id), selection.menu_callback(huge_id), selection.item_callback(huge_id),
             "gr:#{huge_id}:#{huge_id}:h", "gu:#{huge_id}:#{huge_id}:h", "gc:#{huge_id}:#{huge_id}:h",
             "gp:#{huge_id}:#{huge_id}:1:h" ]
    assert data.all? { |value| value.bytesize < 64 }
    assert data.all? { |value| Bot::GuestList.budget_from_callback(value) == "h" }
  end
end
