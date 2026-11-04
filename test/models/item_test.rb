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
    assert_not_empty item.errors[:title]
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
    assert_not_empty zero_price_item.errors[:price]
    assert_not_empty negative_price_item.errors[:price]
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

  test "reservation helpers describe ownership and other users" do
    item = Item.create!(wishlist: @wishlist, title: "Puzzle", reserved_by: @reserver.telegram_id)

    assert item.reserved_by?(@reserver)
    assert_not item.reserved_by?(@owner)
    assert item.reserved_by_other?(@owner)
    assert_not item.reserved_by_other?(@reserver)
  end

  test "reserve_for and release_for update reservation state" do
    item = Item.create!(wishlist: @wishlist, title: "Puzzle")

    assert item.reserve_for!(@reserver)
    assert_equal @reserver.telegram_id, item.reload.reserved_by
    assert_equal 1, item.reservation_version

    assert item.release_for!(@reserver)
    assert_nil item.reload.reserved_by
    assert_equal 2, item.reservation_version
  end

  test "stale instances cannot overwrite another guest's reservation" do
    item = Item.create!(wishlist: @wishlist, title: "Puzzle")
    stale_item = Item.find(item.id)
    other = User.create!(telegram_id: 2003, first_name: "Other")

    assert item.reserve_for!(@reserver)
    assert_not stale_item.reserve_for!(other)
    assert_equal @reserver.telegram_id, stale_item.reserved_by
    assert_equal 1, stale_item.reservation_version
  end

  test "only the current reserver can release and repeated requests do not touch the row" do
    item = Item.create!(wishlist: @wishlist, title: "Puzzle")
    assert item.reserve_for!(@reserver, expected_version: 0)
    reserved_at = item.updated_at

    travel 1.minute do
      assert_not item.reserve_for!(@reserver, expected_version: 0)
      assert_not item.release_for!(@owner, expected_version: 1)
      assert_equal reserved_at, item.updated_at
      assert_equal 1, item.reservation_version
      assert item.release_for!(@reserver, expected_version: 1)
    end

    released_at = item.updated_at
    assert_not item.release_for!(@reserver, expected_version: 1)
    assert_equal released_at, item.updated_at
    assert_nil item.reserved_by
  end

  test "delayed reserve and release requests cannot affect a later reservation cycle" do
    item = Item.create!(wishlist: @wishlist, title: "Puzzle")
    assert item.reserve_for!(@reserver, expected_version: 0)
    assert item.release_for!(@reserver, expected_version: 1)

    assert_not item.reserve_for!(@reserver, expected_version: 0)
    assert_nil item.reserved_by
    assert item.reserve_for!(@reserver, expected_version: 2)
    assert_not item.release_for!(@reserver, expected_version: 1)
    assert_equal @reserver.telegram_id, item.reserved_by
    assert_equal 3, item.reservation_version
  end
end
