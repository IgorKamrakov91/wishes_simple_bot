require "test_helper"

class WishlistTest < ActiveSupport::TestCase
  test "owner_link returns link with full name" do
    user = User.new(first_name: "Jane", last_name: "Doe", telegram_id: 12345)
    wishlist = Wishlist.new(user: user, title: "My List")

    expected_link = "<a href=\"tg://user?id=12345\">Jane Doe</a>"
    assert_equal expected_link, wishlist.owner_link
  end

  test "owner_link works with username fallback" do
    user = User.new(username: "janedoe", telegram_id: 67890)
    wishlist = Wishlist.new(user: user, title: "My List")

    expected_link = "<a href=\"tg://user?id=67890\">janedoe</a>"
    assert_equal expected_link, wishlist.owner_link
  end

  test "owner_link escapes HTML in the display name" do
    user = User.new(first_name: "Jane <Admin>", last_name: "Doe & Co", telegram_id: 24680)
    wishlist = Wishlist.new(user: user, title: "My List")

    expected_link = "<a href=\"tg://user?id=24680\">Jane &lt;Admin&gt; Doe &amp; Co</a>"
    assert_equal expected_link, wishlist.owner_link
    refute_includes wishlist.owner_link, "<Admin>"
  end

  test "shared_with returns lists visible to the given user" do
    owner = User.create!(telegram_id: 1001, first_name: "Owner")
    viewer = User.create!(telegram_id: 1002, first_name: "Viewer")
    other_viewer = User.create!(telegram_id: 1003, first_name: "Other")
    shared_list = Wishlist.create!(user: owner, title: "Shared")
    private_list = Wishlist.create!(user: owner, title: "Private")

    shared_list.list_viewers.create!(user: viewer)
    private_list.list_viewers.create!(user: other_viewer)

    assert_equal [ shared_list ], Wishlist.shared_with(viewer).to_a
  end

  test "has_viewer checks persisted list viewers" do
    owner = User.create!(telegram_id: 1011, first_name: "Owner")
    viewer = User.create!(telegram_id: 1012, first_name: "Viewer")
    wishlist = Wishlist.create!(user: owner, title: "Birthday")

    assert_not wishlist.has_viewer?(viewer)

    wishlist.list_viewers.create!(user: viewer)

    assert wishlist.has_viewer?(viewer)
  end

  test "percentage_fulfilled rounds reserved item progress" do
    owner = User.create!(telegram_id: 1021, first_name: "Owner")
    wishlist = Wishlist.create!(user: owner, title: "Birthday")
    wishlist.items.create!(title: "Book", reserved_by: 2001)
    wishlist.items.create!(title: "Game")
    wishlist.items.create!(title: "Puzzle")

    assert_equal 1, wishlist.reserved_items_count
    assert_equal 33, wishlist.percentage_fulfilled
  end

  test "percentage_fulfilled is zero for empty lists" do
    owner = User.create!(telegram_id: 1031, first_name: "Owner")
    wishlist = Wishlist.create!(user: owner, title: "Empty")

    assert_equal 0, wishlist.percentage_fulfilled
  end
end
