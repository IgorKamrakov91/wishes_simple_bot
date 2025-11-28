require "test_helper"
require "mocha/minitest"

class BotPresentersItemPresenterTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 1001, username: "owner_user", first_name: "Owner")
    @viewer = User.create!(telegram_id: 1002, username: "viewer_user", first_name: "Viewer")
    @reserver = User.create!(telegram_id: 1003, username: "reserver_user", first_name: "Reserver")
    
    @wishlist = Wishlist.create!(user: @owner, title: "Owner's List")
    @item = Item.create!(
      wishlist: @wishlist, 
      title: "Apple 🍎", 
      description: "A red apple", 
      price: 50.0,
      url: "http://apple.com"
    )
    
    @context = mock("Context")
    # Presenter uses context.inline_btn and context.build_keyboard, but primarily we are testing .text method here
    # The .text method doesn't use context, only .keyboard does.
    # So we might not strictly need extensive context mocking if we only test .text
    # But let's mock it to be safe if we instantiate it.
    @context.stubs(:user).returns(@viewer)
  end

  test "renders unreserved item correctly" do
    presenter = Bot::Presenters::ItemPresenter.new(@item, @viewer, @context)
    text = presenter.text

    assert_match "🎁 Apple 🍎", text
    assert_match "💬 A red apple", text
    assert_match "🔗 http://apple.com", text
    assert_match "💵 50.0₽", text
    refute_match "🔒", text
    refute_match "tg-spoiler", text
  end

  test "renders reserved item with spoiler for username" do
    @item.update!(reserved_by: @reserver.telegram_id)
    presenter = Bot::Presenters::ItemPresenter.new(@item, @viewer, @context)
    text = presenter.text

    assert_match "🔒 Apple 🍎", text
    assert_match /🤵 <tg-spoiler>@reserver_user<\/tg-spoiler>/, text
  end

  test "renders reserved item with spoiler for first name if no username" do
    @reserver.update!(username: nil, first_name: "Secret Santa")
    @item.update!(reserved_by: @reserver.telegram_id)
    presenter = Bot::Presenters::ItemPresenter.new(@item, @viewer, @context)
    text = presenter.text

    assert_match /🤵 <tg-spoiler>Secret Santa<\/tg-spoiler>/, text
  end

  test "escapes HTML special characters in fields" do
    @item.update!(
      title: "Me & You <3",
      description: "Quote: \"Hello\"",
      url: "http://site.com?a=1&b=2"
    )
    presenter = Bot::Presenters::ItemPresenter.new(@item, @viewer, @context)
    text = presenter.text

    # Title: Me & You <3 -> Me &amp; You &lt;3
    assert_match "Me &amp; You &lt;3", text
    # Description: Quote: "Hello" -> Quote: &quot;Hello&quot;
    assert_match "Quote: &quot;Hello&quot;", text
    # URL: http://site.com?a=1&b=2 -> http://site.com?a=1&amp;b=2
    assert_match "http://site.com?a=1&amp;b=2", text
    
    # Ensure raw characters are NOT present
    refute_match " <3", text
    refute_match "\"Hello\"", text
    # The URL check is tricky because '&' is present in '&amp;', but we want to ensure standalone '&' isn't there 
    # surrounding the specific params.
    # A simpler check:
    assert text.include?("?a=1&amp;b=2")
  end

  test "escapes HTML in user info" do
    @reserver.update!(username: nil, first_name: "Bad <script> Guy")
    @item.update!(reserved_by: @reserver.telegram_id)
    presenter = Bot::Presenters::ItemPresenter.new(@item, @viewer, @context)
    text = presenter.text

    assert_match "&lt;script&gt;", text
    refute_match "<script>", text
  end
end
