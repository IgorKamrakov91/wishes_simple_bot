require "test_helper"
require "mocha/minitest"
require "telegram/bot"
require "timeout"

Telegram::Bot::Types::Update

class BotUpdateDeliveryTest < ActiveJob::TestCase
  # These tests must observe real commits and separate database connections.
  self.use_transactional_tests = false

  class ProcessCrash < Exception; end

  class RecordingApi
    attr_accessor :failure, :before_call
    attr_reader :calls

    def initialize
      @calls = []
      @mutex = Mutex.new
    end

    %i[send_message edit_message_text answer_callback_query].each do |method|
      define_method(method) do |**params|
        before_call&.call(method, params)
        @mutex.synchronize do
          if failure
            error = failure
            self.failure = nil
            raise error
          end
          calls << [ method, params ]
        end
        true
      end
    end
  end

  setup do
    @owner = User.create!(telegram_id: 99501, first_name: "Owner")
    @guest = User.create!(telegram_id: 99502, first_name: "Guest")
    @wishlist = @owner.wishlists.create!(title: "Private birthday")
    @wishlist.admit!(@guest)
    @api = RecordingApi.new
    @bot = Struct.new(:api).new(@api)
    @update_id = 9_950_100
  end

  teardown do
    @owner&.destroy!
    @guest&.destroy!
    BotUpdateReceipt.where(telegram_user_id: [ 99501, 99502 ]).delete_all
  end

  test "a receipt is unique and contains only technical result metadata" do
    update = gift_update
    dispatch(update)
    receipt = BotUpdateReceipt.find(update.update_id)
    item = @wishlist.items.sole

    assert_equal "gift_added", receipt.result_kind
    assert_equal item.id, receipt.result_id
    assert_equal @owner.telegram_id, receipt.telegram_user_id
    assert receipt.delivered_at
    assert_equal %w[created_at delivered_at result_id result_kind telegram_user_id update_id], receipt.attributes.keys.sort
    refute_includes receipt.attributes.to_s, "Private puzzle"
    refute_includes receipt.attributes.to_s, "private.example"
    assert_raises(ActiveRecord::RecordNotUnique) do
      BotUpdateReceipt.insert_all!([ { update_id: update.update_id, telegram_user_id: @owner.telegram_id, created_at: Time.current } ])
    end
  end

  test "an acknowledged update does not consume a later draft or send a second screen" do
    update = gift_update
    dispatch(update)
    @owner.start_creating_list!
    before = @owner.attributes.slice("bot_state", "bot_payload")
    calls = @api.calls.size

    assert_no_difference("Item.count") { dispatch(update) }

    assert_equal before, @owner.reload.attributes.slice("bot_state", "bot_payload")
    assert_equal calls, @api.calls.size
  end

  test "an exception before commit rolls back both the gift and receipt and keeps input" do
    update = gift_update
    before = @owner.attributes.slice("bot_state", "bot_payload")
    Bot::StateHandler.any_instance.expects(:show_saved_item).raises(StandardError, "PRIVATE_EXCEPTION_TEXT")

    assert_no_difference("Item.count") { dispatch(update) }

    refute BotUpdateReceipt.exists?(update.update_id)
    assert_equal before, @owner.reload.attributes.slice("bot_state", "bot_payload")
    assert_includes last_text, I18n.t("bot.commands.message_failed")
    Bot::StateHandler.any_instance.unstub(:show_saved_item)

    assert_difference("Item.count", 1) { dispatch(update) }
    assert BotUpdateReceipt.find(update.update_id).delivered_at
  end

  test "a process crash before commit leaves the same update safe to execute again" do
    update = gift_update
    Bot::StateHandler.any_instance.expects(:show_saved_item).raises(ProcessCrash)

    assert_raises(ProcessCrash) { dispatch(update) }

    refute BotUpdateReceipt.exists?(update.update_id)
    assert_empty @wishlist.items
    assert_equal "adding_item_url", @owner.reload.bot_state
    assert_nil Bot::UpdateDelivery.current
    Bot::StateHandler.any_instance.unstub(:show_saved_item)

    assert_difference("Item.count", 1) { dispatch(update) }
  end

  test "a new request after a process crash restores a committed gift without replaying input" do
    update = gift_update
    @api.failure = ProcessCrash.new

    assert_raises(ProcessCrash) { dispatch(update) }

    receipt = BotUpdateReceipt.find(update.update_id)
    assert_equal "gift_added", receipt.result_kind
    assert_nil receipt.delivered_at
    assert_equal 1, @wishlist.items.count
    assert_nil @owner.reload.bot_state
    assert_nil Bot::UpdateDelivery.current
    Bot::StateHandler.any_instance.expects(:handle).never

    assert_no_difference("Item.count") { dispatch(update) }

    assert_includes last_text, I18n.t("bot.messages.update_results.gift_added")
    assert_includes last_text, "Private puzzle"
    assert receipt.reload.delivered_at
  end

  test "a timeout after commit confirms the known result and a retry restores the screen" do
    update = gift_update
    @api.failure = Faraday::TimeoutError.new("PRIVATE_TIMEOUT_TEXT")

    dispatch(update)

    assert_equal 1, @wishlist.items.count
    assert_nil BotUpdateReceipt.find(update.update_id).delivered_at
    assert_includes last_text, I18n.t("bot.messages.update_results.gift_added")
    refute_includes last_text, "ничего не сохранено"
    assert_no_difference("Item.count") { dispatch(update) }
    assert BotUpdateReceipt.find(update.update_id).delivered_at
    assert_includes last_text, "Private puzzle"
  end

  test "a crash after Telegram accepts the reply still never repeats the business write" do
    update = gift_update
    BotUpdateReceipt.any_instance.expects(:mark_delivered!).raises(ProcessCrash)

    assert_raises(ProcessCrash) { dispatch(update) }

    assert_equal 1, @api.calls.size
    assert_nil BotUpdateReceipt.find(update.update_id).delivered_at
    BotUpdateReceipt.any_instance.unstub(:mark_delivered!)

    assert_no_difference("Item.count") { dispatch(update) }
    assert BotUpdateReceipt.find(update.update_id).delivered_at
    # Telegram may have accepted the first reply before the process died.
    # Business effects are deduplicated; visible replies cannot be exactly-once.
    assert_equal 2, @api.calls.size
  end

  test "HTTP sees business changes committed from a separate database connection" do
    update = gift_update
    observed = []
    @api.before_call = lambda do |*, **|
      observed << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          [ Item.where(wishlist: @wishlist).count, BotUpdateReceipt.exists?(update.update_id) ]
        end
      end.value
    end

    dispatch(update)

    assert_equal [ [ 1, true ] ], observed
  end

  test "a repeated reservation after a crash does not repeat notifications or change its version" do
    item = @wishlist.items.create!(title: "Private puzzle")
    update = callback_update("reserve_item:#{item.id}:0")
    @api.failure = ProcessCrash.new

    assert_raises(ProcessCrash) { dispatch(update) }

    assert_equal @guest.telegram_id, item.reload.reserved_by
    assert_equal 1, item.reservation_version
    assert_equal 1, notification_count
    item.update!(title: "Current title")
    jobs = notification_count

    dispatch(update)

    assert_equal 1, item.reload.reservation_version
    assert_equal jobs, notification_count
    assert_includes last_text, "Current title"
    assert BotUpdateReceipt.find(update.update_id).delivered_at
    assert_equal :answer_callback_query, @api.calls.last.first
  end

  test "recovery checks current access and does not leak a revoked gift" do
    item = @wishlist.items.create!(title: "Private puzzle")
    update = callback_update("reserve_item:#{item.id}:0")
    @api.failure = ProcessCrash.new
    assert_raises(ProcessCrash) { dispatch(update) }
    @wishlist.list_viewers.where(user: @guest).delete_all

    dispatch(update)

    assert_includes last_text, I18n.t("bot.messages.result_unavailable")
    refute_includes last_text, item.title
    assert_equal @guest.telegram_id, item.reload.reserved_by
    assert_equal 1, item.reservation_version
  end

  test "a deleted result stays deleted and gives recovery navigation" do
    update = gift_update
    @api.failure = ProcessCrash.new
    assert_raises(ProcessCrash) { dispatch(update) }
    @wishlist.items.sole.destroy!

    assert_no_difference("Item.count") { dispatch(update) }

    assert_includes last_text, I18n.t("bot.messages.result_unavailable")
    assert_equal %w[main_menu help], last_params[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
  end

  test "recovery preserves a newer input and never revives the original draft" do
    update = gift_update
    @api.failure = ProcessCrash.new
    assert_raises(ProcessCrash) { dispatch(update) }
    @owner.start_adding_item!(wishlist_id: @wishlist.id)
    before = @owner.attributes.slice("bot_state", "bot_payload")

    dispatch(update)

    assert_equal before, @owner.reload.attributes.slice("bot_state", "bot_payload")
    assert_includes last_text, I18n.t("bot.messages.enter_item_name")
    refute @owner.bot_payload.key?("title")
  end

  test "a repeated setting does not overwrite a newer preference" do
    update = callback_update("set_setting:notify_own_reservations:0", user: @owner)
    @api.failure = ProcessCrash.new
    assert_raises(ProcessCrash) { dispatch(update) }
    @owner.reload.update!(notify_own_reservations: true)

    dispatch(update)

    assert @owner.reload.notify_own_reservations
    assert_includes last_text, I18n.t("bot.messages.update_results.settings_updated")
  end

  test "a rejected reservation restores the current card without claiming success" do
    item = @wishlist.items.create!(title: "Taken puzzle", reserved_by: @owner.telegram_id)
    update = callback_update("reserve_item:#{item.id}:0")
    @api.failure = ProcessCrash.new
    assert_raises(ProcessCrash) { dispatch(update) }
    assert_equal "item_view", BotUpdateReceipt.find(update.update_id).result_kind

    dispatch(update)

    assert_equal @owner.telegram_id, item.reload.reserved_by
    assert_equal 0, item.reservation_version
    assert_includes last_text, "Taken puzzle"
    refute_includes last_text, I18n.t("bot.messages.update_results.reserved")
    assert_equal 0, notification_count
  end

  test "recovery of a deleted gift shows its list and never deletes a newer gift" do
    item = @wishlist.items.create!(title: "Old gift")
    update = callback_update("delete_item:#{item.id}", user: @owner)
    @api.failure = ProcessCrash.new
    assert_raises(ProcessCrash) { dispatch(update) }
    refute Item.exists?(item.id)
    receipt = BotUpdateReceipt.find(update.update_id)
    assert_equal [ "gift_deleted", @wishlist.id ], [ receipt.result_kind, receipt.result_id ]
    newer = @wishlist.items.create!(title: "New gift")

    assert_no_difference("Item.count") { dispatch(update) }

    assert Item.exists?(newer.id)
    assert_includes last_text, I18n.t("bot.messages.update_results.gift_deleted")
    assert_includes last_text, @wishlist.title
  end

  test "recovered purchase and release actions leave reservation versions unchanged" do
    item = @wishlist.items.create!(title: "Private puzzle")
    item.reserve_for!(@guest)
    [ [ "mark_purchased", "1", "purchased" ], [ "mark_purchased", "0", "unpurchased" ],
      [ "unreserve_item", nil, "released" ] ].each do |action, value, result|
      update = callback_update([ action, item.id, item.reservation_version, value ].compact.join(":"))
      @api.failure = ProcessCrash.new
      assert_raises(ProcessCrash) { dispatch(update) }
      version = item.reload.reservation_version
      jobs = notification_count

      dispatch(update)

      assert_equal result, BotUpdateReceipt.find(update.update_id).result_kind
      assert_equal version, item.reload.reservation_version
      assert_equal jobs, notification_count
    end
  end

  test "a receipt cannot be used by a different actor" do
    update = gift_update
    dispatch(update)
    foreign = callback_update("new_list", user: @guest, id: update.update_id)

    assert_no_difference("Wishlist.count") { dispatch(foreign) }

    assert_nil @guest.reload.bot_state
    assert_includes @api.calls.last.last[:text], I18n.t("bot.commands.message_failed")
    refute_includes @api.calls.last.last[:text], "Private puzzle"
  end

  test "two concurrent deliveries execute the mutation once and send one reply" do
    update = message_update("Create a gift")
    started = Queue.new
    proceed = Queue.new
    counter = 0
    counter_lock = Mutex.new
    operation = lambda do
      Bot::UpdateDelivery.call(@bot, update) do
        counter_lock.synchronize { counter += 1 }
        item = @wishlist.items.create!(title: "Private puzzle")
        Bot::UpdateDelivery.record_result("gift_added", item.id)
        started << true
        proceed.pop
        Bot::Context.new(bot: @bot, user: @owner, source: update.message).send_text("Saved")
      end
    end
    threads = [ Thread.new { ActiveRecord::Base.connection_pool.with_connection { operation.call } } ]
    Timeout.timeout(10) { started.pop }
    threads << Thread.new { ActiveRecord::Base.connection_pool.with_connection { operation.call } }
    proceed << true
    Timeout.timeout(10) { threads.each(&:value) }

    assert_equal 1, counter
    assert_equal 1, @wishlist.items.count
    assert_equal 1, @api.calls.size
    assert BotUpdateReceipt.find(update.update_id).delivered_at
  ensure
    threads&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  test "cleanup removes receipts older than two days and keeps recent ones" do
    old = BotUpdateReceipt.create!(update_id: next_update_id, telegram_user_id: @owner.telegram_id, created_at: 3.days.ago)
    recent = BotUpdateReceipt.create!(update_id: next_update_id, telegram_user_id: @owner.telegram_id, created_at: 1.day.ago)

    CleanupBotUpdateReceiptsJob.perform_now

    refute BotUpdateReceipt.exists?(old.update_id)
    assert BotUpdateReceipt.exists?(recent.update_id)
  end

  private

  def next_update_id
    @update_id += 1
  end

  def message_update(text)
    Telegram::Bot::Types::Update.new(update_id: next_update_id, message: {
      message_id: 100, date: 1, text: text,
      chat: { id: @owner.telegram_id, type: "private" },
      from: { id: @owner.telegram_id, is_bot: false, first_name: @owner.first_name }
    })
  end

  def callback_update(data, user: @guest, id: next_update_id)
    Telegram::Bot::Types::Update.new(update_id: id, callback_query: {
      id: "receipt-query", chat_instance: "chat", data: data,
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name },
      message: { message_id: 10, date: 1, chat: { id: user.telegram_id, type: "private" }, text: "Old card" }
    })
  end

  def gift_update
    @owner.update!(bot_state: "adding_item_url", bot_payload: {
      "wishlist_id" => @wishlist.id, "title" => "Private puzzle", "draft_id" => "dprivate"
    })
    message_update("https://private.example/puzzle")
  end

  def dispatch(update)
    Bot::Dispatcher.dispatch(@bot, update)
  end

  def last_params
    @api.calls.reverse.find { |method, _| %i[send_message edit_message_text].include?(method) }&.last || @api.calls.last.last
  end

  def last_text
    last_params.fetch(:text)
  end

  def notification_count
    enqueued_jobs.count { |job| job[:job] == NotificationJob }
  end
end
