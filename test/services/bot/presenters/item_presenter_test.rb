require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotPresentersItemPresenterTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 1001, username: "owner_user", first_name: "Owner")
    @viewer = User.create!(telegram_id: 1002, username: "viewer_user", first_name: "Viewer")
    @reserver = User.create!(telegram_id: 1003, username: "reserver_user", first_name: "Reserver")

    @wishlist = Wishlist.create!(user: @owner, title: "Owner List")
    @item = Item.create!(
      wishlist: @wishlist,
      title: "Apple 🍎",
      description: "A red apple",
      price: 6000,
      url: "https://www.apple.com/iphone"
    )
  end

  def presenter_for(user, item = @item)
    context = Bot::Context.new(bot: mock("TelegramBot"), user: user, source: mock("Source"))
    Bot::Presenters::ItemPresenter.new(item, user, context)
  end

  def button_rows(presenter)
    presenter.keyboard.inline_keyboard
  end

  def callbacks(presenter)
    button_rows(presenter).flatten.map(&:callback_data).compact
  end

  test "renders card details with formatted price and store link" do
    text = presenter_for(@viewer).text

    assert_match "<b>Apple 🍎</b>", text
    assert_match "<i>A red apple</i>", text
    assert_match "<b>6 000 ₽</b>", text
    assert_match "<a href=\"https://www.apple.com/iphone\">apple.com</a>", text
    assert_match "Owner List · 1 из 1", text
  end

  test "guest sees reserve and store buttons but no owner actions" do
    presenter = presenter_for(@viewer)

    assert_includes callbacks(presenter), "reserve_item:#{@item.id}:0"
    assert_equal "success", button_rows(presenter).first.first.style
    refute_includes callbacks(presenter), "edit_item:#{@item.id}"
    assert_equal "https://www.apple.com/iphone", button_rows(presenter)[1].first.url
    assert_match "Owner в боте увидит только, что подарок занят, но не кем", presenter.text
    refute callbacks(presenter).any? { |callback| callback.start_with?("show_reservations:") }
  end

  test "owner can edit and delete but not reserve" do
    presenter = presenter_for(@owner)

    refute_includes callbacks(presenter), "reserve_item:#{@item.id}:0"
    assert button_rows(presenter).flatten.none? { |button| button.callback_data&.start_with?("unreserve_item:") }
    assert_includes callbacks(presenter), "edit_item:#{@item.id}"
    assert_includes callbacks(presenter), "confirm_delete_item:#{@item.id}"
    delete_button = button_rows(presenter).flatten.find { |b| b.callback_data == "confirm_delete_item:#{@item.id}" }
    assert_equal "danger", delete_button.style
    assert_match "пока никто не забронировал", presenter.text
  end

  test "owner does not see who reserved the item" do
    @item.update!(reserved_by: @reserver.telegram_id)
    text = presenter_for(@owner).text

    assert_match "кем — секрет", text
    refute_match "reserver_user", text
  end

  test "guest sees the reserver in a spoiler and cannot reserve" do
    @item.update!(reserved_by: @reserver.telegram_id)
    presenter = presenter_for(@viewer)

    assert_match "<tg-spoiler>@reserver_user</tg-spoiler>", presenter.text
    assert button_rows(presenter).flatten.none? { |button| button.callback_data&.match?(/\A(?:reserve_item|unreserve_item|toggle_reserve):/) }
  end

  test "guest falls back to the reserver's first name" do
    @reserver.update!(username: nil, first_name: "Secret Santa")
    @item.update!(reserved_by: @reserver.telegram_id)

    assert_match "<tg-spoiler>Secret Santa</tg-spoiler>", presenter_for(@viewer).text
  end

  test "guest can cancel their own reservation" do
    @item.reserve_for!(@viewer)
    presenter = presenter_for(@viewer)

    assert_match "Это твоя бронь", presenter.text
    assert_equal [ I18n.t("bot.buttons.purchased"), I18n.t("bot.buttons.unreserve") ], button_rows(presenter).first(2).map { |row| row.first.text }
    assert_includes callbacks(presenter), "mark_purchased:#{@item.id}:1:1"
    assert_includes callbacks(presenter), "unreserve_item:#{@item.id}:1"
    assert_includes callbacks(presenter), "show_reservations:0"
  end

  test "guest can reach other accessible reservations but not revoked or legacy owned bookings" do
    other_list = @owner.wishlists.create!(title: "Other list")
    other_list.admit!(@viewer)
    other_list.items.create!(title: "Book", reserved_by: @viewer.telegram_id)
    assert_includes callbacks(presenter_for(@viewer)), "show_reservations:0"

    other_list.list_viewers.where(user: @viewer).delete_all
    own_list = @viewer.wishlists.create!(title: "My list")
    own_list.items.create!(title: "Legacy booking", reserved_by: @viewer.telegram_id)
    refute callbacks(presenter_for(@viewer)).any? { |callback| callback.start_with?("show_reservations:") }
  end

  test "link preview shows the shop page" do
    options = presenter_for(@viewer).link_preview_options

    assert_equal "https://www.apple.com/iphone", options.url
    assert options.prefer_large_media
  end

  test "non-web links are shown as text without a URL button" do
    # Saved before links had to be http(s)
    @item.update_column(:url, "apple store <b>")
    presenter = presenter_for(@viewer)

    assert_match "apple store &lt;b&gt;", presenter.text
    assert button_rows(presenter).flatten.none?(&:url)
    assert presenter.link_preview_options.is_disabled
  end

  test "renders reserved item with fallback label when reserver no longer exists" do
    @item.update!(reserved_by: 999_999)
    text = presenter_for(@viewer).text

    assert_match "<tg-spoiler>#{I18n.t("bot.presenters.item.unknown_reserver")}</tg-spoiler>", text
  end

  test "escapes HTML special characters in fields" do
    @item.update!(title: "Me & You <3", description: "Quote: \"Hello\"")
    text = presenter_for(@viewer).text

    assert_match "Me &amp; You &lt;3", text
    assert_match "Quote: &quot;Hello&quot;", text
    refute_match " <3", text
  end

  test "escapes HTML in user info" do
    @reserver.update!(username: nil, first_name: "Bad <script> Guy")
    @item.update!(reserved_by: @reserver.telegram_id)
    text = presenter_for(@viewer).text

    assert_match "&lt;script&gt;", text
    refute_match "<script>", text
  end

  test "navigates between neighbouring items" do
    second = Item.create!(wishlist: @wishlist, title: "Pear")
    third = Item.create!(wishlist: @wishlist, title: "Plum")

    *, neighbours, back = button_rows(presenter_for(@viewer, second))

    assert_equal [ "open_item:#{@item.id}", "open_item:#{third.id}" ], neighbours.map(&:callback_data)
    assert_equal [ I18n.t("bot.buttons.prev_item"), I18n.t("bot.buttons.next_item") ], neighbours.map(&:text)
    assert_equal [ "list_page:#{@wishlist.id}:0" ], back.map(&:callback_data)
  end

  test "the first and last gifts have no placeholder buttons" do
    second = Item.create!(wishlist: @wishlist, title: "Pear")

    *, neighbours, _back = button_rows(presenter_for(@viewer, @item))
    assert_equal [ "open_item:#{second.id}" ], neighbours.map(&:callback_data)

    *, neighbours, _back = button_rows(presenter_for(@viewer, second))
    assert_equal [ "open_item:#{@item.id}" ], neighbours.map(&:callback_data)
    assert button_rows(presenter_for(@viewer, second)).flatten.none? { |b| b.callback_data == "noop" }
  end
end
