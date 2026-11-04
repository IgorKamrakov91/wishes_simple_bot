require "test_helper"
require "mocha/minitest"

# /help and the card texts describe what the bot really shows
class BotPrivacyContractTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 95001, first_name: "Игорь")
    @reserver = User.create!(telegram_id: 95002, first_name: "Анна", username: "anna_gifts")
    @other = User.create!(telegram_id: 95003, first_name: "Олег")
    @wishlist = @owner.wishlists.create!(title: "ДР")
    [ @reserver, @other ].each { |user| @wishlist.admit!(user) }
    @item = @wishlist.items.create!(title: "Плед")
    @item.reserve_for!(@reserver)
  end

  def card_for(user)
    context = mock("BotContext")
    context.stubs(:inline_btn).returns(:button)
    context.stubs(:build_keyboard).returns(:keyboard)
    Bot::Presenters::ItemPresenter.new(@item.reload, user, context).text
  end

  test "the owner sees that a gift is taken but not who took it" do
    text = card_for(@owner)

    assert_includes text, I18n.t("bot.screens.item.owner_reserved")
    refute_includes text, "anna_gifts"
    refute_includes text, "Анна"
  end

  test "other guests see the reserver's name under a spoiler" do
    assert_includes card_for(@other), "<tg-spoiler>@anna_gifts</tg-spoiler>"
  end

  test "help says the same" do
    help = I18n.t("bot.commands.help")

    assert_includes help, "не видит, кто его забронировал"
    assert_includes help, "под спойлером"
    assert_includes help, "её можно переслать"
  end
end
