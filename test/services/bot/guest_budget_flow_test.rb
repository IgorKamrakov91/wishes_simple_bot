require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotGuestBudgetFlowTest < ActiveJob::TestCase
  setup do
    @owner = User.create!(telegram_id: 97811, first_name: "Owner", notify_own_reservations: false)
    @guest = User.create!(telegram_id: 97812, first_name: "Guest")
    @list = @owner.wishlists.create!(title: "Birthday <&>")
    @list.admit!(@guest)
    @screens = []
    @answers = []
    @edit_state = {}
    screens, answers, state = @screens, @answers, @edit_state
    api = Object.new
    api.define_singleton_method(:edit_message_text) do |**params|
      screens << params
      raise state.delete(:error) if state[:error]
    end
    api.define_singleton_method(:answer_callback_query) { |**params| answers << params }
    @bot = stub(api: api)
    @update_id = 9_781_000
    Telegram::Bot::Client.expects(:new).never
    NotificationJob.expects(:perform_later).never
  end

  test "a guest opens free gifts first across pages while full-list progress stays accurate" do
    taken = gift("Taken", reserved_by: @guest.telegram_id)
    free = 7.times.map { |i| gift("Free #{i}") }
    press("open_list:#{@list.id}")
    assert_equal free.first(5).map(&:id), item_ids
    assert_includes text, "1 из 8 забронировано"
    assert_includes text, "Birthday &lt;&amp;&gt;"
    assert_includes callbacks, "gl:#{@list.id}:1:a"

    press("gl:#{@list.id}:1:a")
    assert_equal [ *free.last(2).map(&:id), taken.id ], item_ids
    assert_includes callbacks, "gl:#{@list.id}:0:a"
    refute_includes callbacks, "gl:#{@list.id}:2:a"
  end

  test "numeric budgets keep unpriced gifts and the menu can reset the selection" do
    cheap = 6.times.map { |i| gift("Cheap #{i}", price: "1000.00") }
    unpriced = gift("No price")
    gift("Above the ceiling", price: "1000.01")
    press("gf:#{@list.id}:1:a")
    assert_equal Bot::GuestList::BUDGETS.map { |key| "gl:#{@list.id}:0:#{key}" } + [ "gl:#{@list.id}:1:a" ], callbacks

    press("gl:#{@list.id}:0:s")
    assert_equal cheap.first(5).map(&:id), item_ids
    press("gl:#{@list.id}:1:s")
    assert_equal [ cheap.last.id, unpriced.id ], item_ids
    assert_includes callbacks, "gl:#{@list.id}:0:s"
    press("gf:#{@list.id}:1:s")
    assert_includes buttons.map(&:text), "✓ #{I18n.t('bot.guest_budget.options.s')}"
    press("gl:#{@list.id}:0:n")
    assert_equal [ unpriced.id ], item_ids
    press("gl:#{@list.id}:0:a")
    assert_includes callbacks, "gl:#{@list.id}:1:a"
  end

  test "an empty match can be reset and an entirely empty list stays readable" do
    expensive = gift("Expensive", price: 5000)
    press("gl:#{@list.id}:4:s")
    assert_empty item_ids
    assert_includes text, I18n.t("bot.guest_budget.empty")
    assert_includes callbacks, "gf:#{@list.id}:0:s"
    press("gl:#{@list.id}:0:a")
    assert_equal [ expensive.id ], item_ids

    expensive.destroy!
    press("gl:#{@list.id}:4:s")
    assert_includes text, I18n.t("bot.screens.list.guest_empty")
    refute callbacks.any? { |data| data.start_with?("gl:", "gf:") }
  end

  test "owner text order and buttons ignore guest filter callbacks" do
    taken = gift("Taken", reserved_by: @guest.telegram_id, price: 5000)
    free = gift("Free", price: 500)
    press("open_list:#{@list.id}", as: @owner)
    original = @screens.last.slice(:text, :reply_markup)
    assert_equal [ "open_item:#{taken.id}", "open_item:#{free.id}" ], callbacks.first(2)
    refute callbacks.any? { |data| data.match?(/\Ag[lfirupc]:/) }

    press("gl:#{@list.id}:0:s", as: @owner)
    assert_equal original[:text], text
    assert_equal original[:reply_markup].to_json, @screens.last[:reply_markup].to_json
    press("gf:#{@list.id}:0:s", as: @owner)
    assert_equal original[:reply_markup].to_json, @screens.last[:reply_markup].to_json
  end

  test "item navigation and back retain the budget and use the new position after booking" do
    matches = 12.times.map { |i| gift("Match #{i}", price: 2000) }
    unpriced = gift("No price")
    gift("Outside", price: 9000)
    press("gi:#{matches.first.id}:m")
    assert_includes callbacks, "gi:#{matches.second.id}:m"
    assert_includes callbacks, "gl:#{@list.id}:0:m"
    refute_includes text, "из 14"

    press("gr:#{matches.first.id}:0:m")
    assert_equal @guest.telegram_id, matches.first.reload.reserved_by
    assert_includes callbacks, "gl:#{@list.id}:2:m"
    press("gl:#{@list.id}:2:m")
    assert_equal [ matches.last.id, unpriced.id, matches.first.id ], item_ids
    refute_includes text, "Outside"
  end

  test "reserve purchase cancel confirmation and release keep the budget and reservation guards" do
    item = gift("Puzzle", price: 2500)
    2.times { press("gr:#{item.id}:0:m") }
    assert_equal 1, item.reload.reservation_version
    assert_includes callbacks, "gp:#{item.id}:1:1:m"
    press("gp:#{item.id}:1:1:m")
    assert item.reload.purchased?
    assert_includes callbacks, "gc:#{item.id}:2:m"
    press("gc:#{item.id}:2:m")
    assert_equal [ "gu:#{item.id}:2:m", "gi:#{item.id}:m" ], callbacks
    press("gi:#{item.id}:m")
    assert item.reload.purchased?
    press("gc:#{item.id}:2:m")
    press("gu:#{item.id}:2:m")
    assert_nil item.reload.reserved_by
    assert_nil item.purchased_at
    assert_includes callbacks, "gr:#{item.id}:3:m"
    press("gr:#{item.id}:0:m")
    assert_nil item.reload.reserved_by
  end

  test "guessed callbacks cannot reveal lists reserve gifts or admit a stranger" do
    stranger = User.create!(telegram_id: 97813, first_name: "Stranger")
    item = gift("Private gift", price: 500)
    [ "gl:#{@list.id}:0:s", "gf:#{@list.id}:0:s", "gi:#{item.id}:s", "gr:#{item.id}:0:s",
      "gu:#{item.id}:0:s", "gc:#{item.id}:0:s", "gp:#{item.id}:0:1:s" ].each do |data|
      press(data, as: stranger)
      assert_equal I18n.t("bot.messages.not_available"), @answers.last[:text]
    end
    assert_empty @screens
    assert_nil item.reload.reserved_by
    refute @list.has_viewer?(stranger)

    @list.list_viewers.delete_all
    press("gf:#{@list.id}:0:s")
    assert_empty @screens
  end

  test "stale prices and deleted gifts clamp pages without an unusable item card" do
    matches = 6.times.map { |i| gift("Gift #{i}", price: 500) }
    press("gl:#{@list.id}:1:s")
    assert_equal [ matches.last.id ], item_ids
    matches.last.update!(price: 1500)
    press("gl:#{@list.id}:99:s")
    assert_equal matches.first(5).map(&:id), item_ids
    refute callbacks.any? { |data| data.start_with?("gl:") }

    matches.first(5).each(&:destroy!)
    press("gi:#{matches.last.id}:s")
    assert_includes text, I18n.t("bot.screens.item.position", index: 1, total: 1)
    assert_includes callbacks, "gl:#{@list.id}:0:s"
    press("gl:#{@list.id}:0:s")
    assert_includes text, I18n.t("bot.guest_budget.empty")
    matches.last.destroy!
    before = @screens.size
    press("gi:#{matches.last.id}:s")
    assert_equal before, @screens.size
    assert_equal I18n.t("bot.messages.not_available"), @answers.last[:text]
  end

  test "guest browsing does not overwrite an unfinished gift in another list" do
    own = @guest.wishlists.create!(title: "My list")
    item = gift("Gift", price: 500)
    @guest.update!(bot_state: "adding_item_title", bot_payload: { "wishlist_id" => own.id, "url" => "https://example.com/gift" })
    payload = @guest.bot_payload
    [ "gf:#{@list.id}:0:a", "gl:#{@list.id}:0:s", "gi:#{item.id}:s", "gr:#{item.id}:0:s" ].each do |data|
      press(data)
      assert_equal "adding_item_title", @guest.reload.bot_state
      assert_equal payload, @guest.bot_payload
    end
  end

  test "both locales explain the filter without hiding the unpriced option" do
    gift("Gift", price: 500)
    %i[ru en].each do |locale|
      I18n.with_locale(locale) do
        press("gf:#{@list.id}:0:m")
        assert_includes text, I18n.t("bot.guest_budget.menu")
        assert_includes buttons.map(&:text), I18n.t("bot.guest_budget.options.n")
        press("gl:#{@list.id}:0:m")
        assert_includes text, I18n.t("bot.guest_budget.hint", budget: I18n.t("bot.guest_budget.options.m"), count: 1)
        refute_includes text, "Translation missing"
        assert callbacks.all? { |data| data.bytesize < 64 }
      end
    end
  end

  test "recovery after a failed page reply keeps the filter and page" do
    matches = 7.times.map { |i| gift("Gift #{i}", price: 2500) }
    gift("Outside", price: 9000)
    @edit_state[:error] = Faraday::TimeoutError.new
    press("gl:#{@list.id}:1:m", update_id: 9_789_001)
    receipt = BotUpdateReceipt.find(9_789_001)
    assert_nil receipt.delivered_at
    press("gl:#{@list.id}:1:m", update_id: 9_789_001)
    assert_equal matches.last(2).map(&:id), item_ids
    assert_includes callbacks, "gl:#{@list.id}:0:m"
    assert receipt.reload.delivered_at
  end

  test "recovery after a committed reservation keeps the filter without repeating the write" do
    item = gift("Gift", price: 500)
    @edit_state[:error] = Faraday::TimeoutError.new
    press("gr:#{item.id}:0:s", update_id: 9_789_002)
    assert_equal 1, item.reload.reservation_version
    assert_nil BotUpdateReceipt.find(9_789_002).delivered_at
    press("gr:#{item.id}:0:s", update_id: 9_789_002)
    assert_equal 1, item.reload.reservation_version
    assert_includes callbacks, "gu:#{item.id}:1:s"
    assert_includes callbacks, "gl:#{@list.id}:0:s"
    assert BotUpdateReceipt.find(9_789_002).delivered_at
  end

  private

  def gift(title, **attributes)
    @list.items.create!(title: title, **attributes)
  end

  def press(data, as: @guest, update_id: nil)
    @update_id += 1
    update = Telegram::Bot::Types::Update.new(
      update_id: update_id || @update_id,
      callback_query: { id: "guest-budget", chat_instance: "chat", data: data,
                        from: { id: as.telegram_id, is_bot: false, first_name: as.first_name },
                        message: { message_id: 7, date: 1, chat: { id: as.telegram_id, type: "private" }, text: "List" } }
    )
    Bot::Dispatcher.dispatch(@bot, update)
  end

  def text
    @screens.last[:text]
  end

  def buttons
    @screens.last[:reply_markup].inline_keyboard.flatten
  end

  def callbacks
    buttons.filter_map(&:callback_data)
  end

  def item_ids
    callbacks.filter_map { |data| /\Agi:(\d+):[asmlhn]\z/.match(data)&.captures&.first&.to_i }
  end
end
