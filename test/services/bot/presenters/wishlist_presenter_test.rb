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
    assert_equal [ I18n.t("bot.buttons.next_page") ], first_page[5].map(&:text)
    assert_match I18n.t("bot.screens.list.page", page: 1, total: 2), presenter_for(@owner).text

    second_page = rows(presenter_for(@owner, page: 1))
    assert_equal [ "Gift 6", "Gift 7" ], second_page.first(2).map { |row| row.first.text }
    assert_equal [ I18n.t("bot.buttons.prev_page") ], second_page[2].map(&:text)
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
    assert_equal "https://t.me/TestBot?start=l_#{@wishlist.share_token}", share.copy_text.text
    assert buttons.any? { |b| b.callback_data == "list_settings:#{@wishlist.id}" }
    assert_equal "Taken · 1 900 ₽ · занято", buttons.first.text
    assert_equal "danger", buttons.first.style
    assert_match "2 подарка · забронировано 1", presenter.text
    refute_match "%", presenter.text
  end

  test "guest sees owner, own reservations and no owner actions" do
    other = User.create!(telegram_id: 3003, first_name: "Other")
    Item.create!(wishlist: @wishlist, title: "Mine", reserved_by: @guest.telegram_id)
    Item.create!(wishlist: @wishlist, title: "Theirs", reserved_by: other.telegram_id)
    Item.create!(wishlist: @wishlist, title: "Free")
    presenter = presenter_for(@guest)
    buttons = rows(presenter).flatten

    assert_equal [ "★ Mine · твоя бронь", "Theirs · занято", "Free" ], buttons.first(3).map(&:text)
    assert_equal [ "success", "danger", nil ], buttons.first(3).map(&:style)
    assert_match "3 подарка · уже выбрали 2", presenter.text
    assert_match "tg://user?id=3001", presenter.text
    assert buttons.none?(&:copy_text)
    assert_equal "show_shared_lists:0", buttons.last.callback_data
  end

  test "empty list invites the owner to add a gift" do
    presenter = presenter_for(@owner)

    assert_match I18n.t("bot.screens.list.owner_empty"), presenter.text
    add_button = rows(presenter).first.first
    assert_equal "add_item:#{@wishlist.id}", add_button.callback_data
    assert_equal "primary", add_button.style
    assert_includes presenter.keyboard.to_json, %("style":"primary")
  end
end
