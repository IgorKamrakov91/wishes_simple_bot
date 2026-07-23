require "test_helper"

class ItemTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 2001, first_name: "Owner")
    @reserver = User.create!(telegram_id: 2002, first_name: "Reserver")
    @wishlist = Wishlist.create!(user: @owner, title: "Birthday")
  end

  test "requires a title" do
    item = Item.new(wishlist: @wishlist, title: "")

    assert_not item.valid?
    assert_includes item.errors[:title], "can't be blank"
  end

  test "allows positive or blank prices" do
    assert Item.new(wishlist: @wishlist, title: "Book", price: 10.50).valid?
    assert Item.new(wishlist: @wishlist, title: "Surprise", price: nil).valid?
  end

  test "rejects zero and negative prices" do
    zero_price_item = Item.new(wishlist: @wishlist, title: "Freebie", price: 0)
    negative_price_item = Item.new(wishlist: @wishlist, title: "Invalid", price: -1)

    assert_not zero_price_item.valid?
    assert_not negative_price_item.valid?
    assert_includes zero_price_item.errors[:price], "must be greater than 0"
    assert_includes negative_price_item.errors[:price], "must be greater than 0"
  end

  test "reserver returns the user matching the reserved telegram id" do
    item = Item.create!(wishlist: @wishlist, title: "Puzzle", reserved_by: @reserver.telegram_id)

    assert item.reserved?
    assert_equal @reserver, item.reserver
  end

  test "reserver is nil when an item is not reserved" do
    item = Item.create!(wishlist: @wishlist, title: "Puzzle")

    assert_not item.reserved?
    assert_nil item.reserver
  end
end
