require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do
Telegram::Bot::Types::Update

class BotReservationNotificationsTest < ActiveJob::TestCase
  setup do
    @owner = User.create!(telegram_id: 91001, first_name: "Игорь")
    @guest = User.create!(telegram_id: 91002, first_name: "Анна")
    @friend = User.create!(telegram_id: 91003, first_name: "Олег", notify_friend_reservations: true)
    @quiet = User.create!(telegram_id: 91004, first_name: "Тихий")
    @wishlist = @owner.wishlists.create!(title: "День рождения")
    [ @guest, @friend, @quiet ].each { |user| @wishlist.admit!(user) }
    @item = @wishlist.items.create!(title: "Плед")

    @api = mock("TelegramApi")
    @api.stubs(:edit_message_text)
    @api.stubs(:answer_callback_query)
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
  end

  def press(data, user: @guest)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "1", chat_instance: "chat", data: data,
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name },
      message: { message_id: 7, date: 1, chat: { id: user.telegram_id, type: "private" }, text: "Card" }
    ))
  end

  def recipients
    enqueued_jobs.select { |job| job["job_class"] == "NotificationJob" }.map { |job| job["arguments"].first(2) }
  end

  test "a reservation tells the owner and guests who asked for it, but not the one who reserved" do
    press("reserve_item:#{@item.id}:0")

    assert_equal [ [ @owner.telegram_id, "own_reserved" ], [ @friend.telegram_id, "friend_reserved" ] ].sort, recipients.sort
  end

  test "pressing reserve twice notifies once" do
    2.times { press("reserve_item:#{@item.id}:0") }

    assert_equal 2, recipients.size
  end

  test "releasing a reservation notifies the same people" do
    @item.reserve_for!(@guest)
    press("unreserve_item:#{@item.id}:1")

    assert_equal [ [ @owner.telegram_id, "own_released" ], [ @friend.telegram_id, "friend_released" ] ].sort, recipients.sort
  end

  test "an owner who turned notifications off gets none" do
    @owner.update!(notify_own_reservations: false)
    press("reserve_item:#{@item.id}:0")

    assert_equal [ @friend.telegram_id ], recipients.map(&:first)
  end

  test "the texts have no place for the person who reserved" do
    %i[ru en].each do |locale|
      I18n.t("bot.notifications", locale: locale).each_value do |text|
        assert_equal [], text.scan(/%\{(\w+)\}/).flatten - %w[title list owner], text
      end
    end
  end

  test "the main menu leads to settings" do
    edits = []
    @api.stubs(:edit_message_text).with { |params| edits << params; true }
    press("main_menu", user: @owner)

    assert_includes edits.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data), "settings"
  end

  test "deleting a reserved gift notifies nobody" do
    @item.reserve_for!(@guest)
    press("delete_item:#{@item.id}", user: @owner)

    assert_empty recipients
  end

  test "settings toggle both kinds of notifications" do
    edits = []
    answers = []
    @api.stubs(:edit_message_text).with { |params| edits << params; true }
    @api.stubs(:answer_callback_query).with { |params| answers << params[:text]; true }

    press("settings", user: @quiet)
    labels = edits.last[:reply_markup].inline_keyboard.flatten.map(&:text)
    assert_includes labels, I18n.t("bot.screens.settings.notify_own_reservations", state: I18n.t("bot.screens.settings.on"))
    assert_includes labels, I18n.t("bot.screens.settings.notify_friend_reservations", state: I18n.t("bot.screens.settings.off"))

    callbacks = edits.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_includes callbacks, "set_setting:notify_friend_reservations:1"
    assert_includes callbacks, "set_setting:notify_own_reservations:0"

    press("set_setting:notify_friend_reservations:1", user: @quiet)
    assert_equal "Уведомления о списках друзей включены", answers.last
    press("set_setting:notify_own_reservations:0", user: @quiet)
    assert_equal "Уведомления о моих списках выключены", answers.last
    @quiet.reload
    assert @quiet.notify_friend_reservations
    refute @quiet.notify_own_reservations

    press("set_setting:telegram_id:1", user: @quiet)
    assert_equal 91004, @quiet.reload.telegram_id
  end

  test "a repeated delivery of the same press keeps the choice" do
    2.times { press("set_setting:notify_own_reservations:0", user: @quiet) }

    refute @quiet.reload.notify_own_reservations
  end

  test "nothing is enqueued when the reservation is rolled back" do
    ActiveRecord::Base.transaction do
      @item.reserve_for!(@guest)
      Bot::ReservationNotifier.reserved(@item, by: @guest)
      raise ActiveRecord::Rollback
    end

    assert_empty recipients
    assert_nil @item.reload.reserved_by
  end

  test "jobs queued under the old deletion name finish without sending" do
    Telegram::Bot::Client.expects(:new).never

    ReservedGiftDeletedJob.perform_now(@guest.telegram_id, "item_deleted", {}, "ru")
  end
end

class NotificationJobRecheckTest < ActiveJob::TestCase
  setup do
    @owner = User.create!(telegram_id: 92001, first_name: "Игорь")
    @friend = User.create!(telegram_id: 92002, first_name: "Олег", notify_friend_reservations: true)
    @wishlist = @owner.wishlists.create!(title: "ДР")
    @wishlist.admit!(@friend)
    @details = { "wishlist_id" => @wishlist.id, "title" => "Плед", "list" => "ДР", "owner" => "Игорь" }
    Telegram::Bot::Client.stubs(:new).returns(stub(api: (@api = mock("TelegramApi"))))
  end

  test "a guest who turned notifications off before delivery gets nothing" do
    @friend.update!(notify_friend_reservations: false)
    @api.expects(:send_message).never

    NotificationJob.perform_now(@friend.telegram_id, "friend_reserved", @details, "ru")
  end

  test "a guest who lost access to the list gets nothing" do
    ListViewer.where(user: @friend).delete_all
    @api.expects(:send_message).never

    NotificationJob.perform_now(@friend.telegram_id, "friend_reserved", @details, "ru")
  end

  test "an owner who turned notifications off before delivery gets nothing" do
    @owner.update!(notify_own_reservations: false)
    @api.expects(:send_message).never

    NotificationJob.perform_now(@owner.telegram_id, "own_reserved", @details, "ru")
  end
end
