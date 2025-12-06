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
end
