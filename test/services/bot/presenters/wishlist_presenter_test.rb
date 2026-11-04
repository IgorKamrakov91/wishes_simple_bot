require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotPresentersWishlistPresenterTest < ActiveSupport::TestCase
  setup do
    ENV["BOT_USERNAME"] = "TestBot"

    @owner = User.create!(telegram_id: 3001, first_name: "Anna")
    @guest = User.create!(telegram_id: 3002, first_name: "Guest")
    @wishlist = Wishlist.create!(user: @owner, title: "Birthday")
  end

  teardown do
    ENV.delete("BOT_USERNAME")
  end

  def presenter_for(user, page: 0)
    context = Bot::Context.new(bot: mock("TelegramBot"), user: user, source: mock("Source"))
    Bot::Presenters::WishlistPresenter.new(@wishlist.reload, user, context, page: page)
  end

  def rows(presenter)
    presenter.keyboard.inline_keyboard
  end

  test "paginates items five per page" do
    7.times { |i| Item.create!(wishlist: @wishlist, title: "Gift #{i + 1}") }

    first_page = rows(presenter_for(@owner))
    assert_equal (1..5).map { |i| "Gift #{i}" }, first_page.first(5).map { |row| row.first.text }
    assert_equal [ "·", "1 / 2", "›" ], first_page[5].map(&:text)

    second_page = rows(presenter_for(@owner, page: 1))
    assert_equal [ "Gift 6", "Gift 7" ], second_page.first(2).map { |row| row.first.text }
    assert_equal [ "‹", "2 / 2", "·" ], second_page[2].map(&:text)
  end

  test "clamps a page that no longer exists" do
    Item.create!(wishlist: @wishlist, title: "Only gift")

    assert_equal 0, presenter_for(@owner, page: 3).page
  end

  test "owner gets share link, settings and progress" do
    Item.create!(wishlist: @wishlist, title: "Taken", reserved_by: @guest.telegram_id, price: 1900)
    Item.create!(wishlist: @wishlist, title: "Free")
    presenter = presenter_for(@owner)
    buttons = rows(presenter).flatten

    share = buttons.find(&:copy_text)
    assert_equal "https://t.me/TestBot?start=list_#{@wishlist.id}", share.copy_text.text
    assert buttons.any? { |b| b.callback_data == "list_settings:#{@wishlist.id}" }
    assert_equal "✓ Taken · 1 900 ₽", buttons.first.text
    assert_match "▰▰▰▰▰▱▱▱▱▱ <b>50%</b>", presenter.text
  end

  test "guest sees owner, own reservations and no owner actions" do
    other = User.create!(telegram_id: 3003, first_name: "Other")
    Item.create!(wishlist: @wishlist, title: "Mine", reserved_by: @guest.telegram_id)
    Item.create!(wishlist: @wishlist, title: "Theirs", reserved_by: other.telegram_id)
    presenter = presenter_for(@guest)
    buttons = rows(presenter).flatten

    assert_equal [ "★ Mine", "✓ Theirs" ], buttons.first(2).map(&:text)
    assert_match "tg://user?id=3001", presenter.text
    assert buttons.none?(&:copy_text)
    assert_equal "show_shared_lists", buttons.last.callback_data
  end

  test "empty list invites the owner to add a gift" do
    presenter = presenter_for(@owner)

    assert_match I18n.t("bot.screens.list.owner_empty"), presenter.text
    assert_equal "add_item:#{@wishlist.id}", rows(presenter).first.first.callback_data
  end
end
