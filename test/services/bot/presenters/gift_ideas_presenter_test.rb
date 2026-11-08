require "test_helper"
require "telegram/bot"

class BotPresentersGiftIdeasPresenterTest < ActiveSupport::TestCase
  Suggestion = Struct.new(:id, :wishlist, :wishlist_id, :status, :ideas, :created_at, keyword_init: true) do
    def failed?
      status == "failed"
    end
  end

  setup do
    owner = User.create!(telegram_id: 98101, first_name: "Owner")
    @wishlist = owner.wishlists.create!(title: "Books & <art>")
    @suggestion = Suggestion.new(id: 17, wishlist: @wishlist, wishlist_id: @wishlist.id, status: "ready",
                                ideas: [ { "title" => "Paint & <paper>", "item_id" => nil },
                                         { "title" => "Sketchbook", "item_id" => 45 } ], created_at: Time.current)
  end

  test "ready ideas escape HTML and keep stable zero-based callback indices" do
    presenter = Bot::Presenters::GiftIdeasPresenter.new(@suggestion)

    assert_includes presenter.text, "Books &amp; &lt;art&gt;"
    assert_includes presenter.text, "1. Paint &amp; &lt;paper&gt;"
    assert_includes presenter.text, "2. ✓ Sketchbook"
    buttons = presenter.keyboard.inline_keyboard.flatten
    assert_equal [ "add_idea:17:0", "open_item:45", "open_list:#{@wishlist.id}" ], buttons.map(&:callback_data)
    assert buttons.map(&:callback_data).all? { |data| data.bytesize <= 64 }
    assert_nil buttons.first.url
  end

  test "long button labels do not change the stored gift title" do
    title = "Красивый набор для рисования акварельными карандашами"
    @suggestion.ideas = [ { "title" => title, "item_id" => nil } ]
    presenter = Bot::Presenters::GiftIdeasPresenter.new(@suggestion)

    assert_includes presenter.text, title
    assert_operator presenter.keyboard.inline_keyboard.first.first.text.length, :<=, 37
    assert_equal title, @suggestion.ideas.first["title"]
  end

  test "expired ideas have recovery navigation and cannot be added" do
    @suggestion.created_at = 3.days.ago
    presenter = Bot::Presenters::GiftIdeasPresenter.new(@suggestion)

    assert_includes presenter.text, I18n.t("bot.gift_ideas.expired")
    refute_includes presenter.text, "Paint"
    assert_equal [ "open_list:#{@wishlist.id}" ], presenter.keyboard.inline_keyboard.flatten.map(&:callback_data)
  end

  test "pending processing and failed results work without a callback context" do
    %w[pending processing failed].each do |status|
      @suggestion.status = status
      presenter = Bot::Presenters::GiftIdeasPresenter.new(@suggestion)

      key = status == "failed" ? "failed" : "waiting"
      assert_includes presenter.text, I18n.t("bot.gift_ideas.#{key}")
      assert_equal [ "open_list:#{@wishlist.id}" ], presenter.keyboard.inline_keyboard.flatten.map(&:callback_data)
    end
  end

  test "empty output is a failure rather than a successful empty list" do
    @suggestion.ideas = []

    assert_includes Bot::Presenters::GiftIdeasPresenter.new(@suggestion).text, I18n.t("bot.gift_ideas.failed")
  end

  test "the job can use either locale and the search URL only targets Market" do
    I18n.with_locale(:en) do
      presenter = Bot::Presenters::GiftIdeasPresenter.new(@suggestion)
      assert_includes presenter.text, "Ideas for"
      assert_includes presenter.text, I18n.t("bot.gift_ideas.ready_hint")
    end
    title = "Краски & бумага #1 / 2?"
    url = URI.parse(Bot::Presenters::GiftIdeasPresenter.market_url(title))

    assert_equal "https", url.scheme
    assert_equal "market.yandex.ru", url.host
    assert_equal "/search", url.path
    assert_equal({ "text" => title }, CGI.parse(url.query).transform_values(&:first))
    assert_nil url.fragment
  end
end
