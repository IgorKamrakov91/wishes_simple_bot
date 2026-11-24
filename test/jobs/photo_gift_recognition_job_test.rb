require "test_helper"
require "mocha/minitest"

class PhotoGiftRecognitionJobTest < ActiveJob::TestCase
  Result = YandexAi::PhotoReader::Result

  setup do
    @env = ENV.to_h.slice("TELEGRAM_BOT_TOKEN", "PHOTO_GIFTS_ENABLED")
    ENV["TELEGRAM_BOT_TOKEN"] = "token"
    ENV["PHOTO_GIFTS_ENABLED"] = "true"
    GiftSuggestion.stubs(:enabled?).returns(true)
    @owner = User.create!(telegram_id: 97_301, first_name: "Owner", photo_ai_consented_at: Time.current)
    @list = @owner.wishlists.create!(title: "Birthday")
    @sent = []
    @api = stub("api")
    @api.stubs(:send_message).with { |params| @sent << params; true }
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
    @files = stub("files")
    @files.stubs(:download).returns("\xFF\xD8\xFFjpeg".b)
    Bot::TelegramFile.stubs(:new).returns(@files)
    @reader = stub("reader")
    YandexAi::PhotoReader.stubs(:new).returns(@reader)
  end

  teardown { @env.each { |key, value| ENV[key] = value } }

  def start(caption: nil)
    draft = nil
    assert_enqueued_jobs(1, only: PhotoGiftRecognitionJob) do
      draft = PhotoGiftDraft.start!(@owner, chat_id: @owner.telegram_id, message_id: 10 + PhotoGiftDraft.count,
        file_id: "photo-large", file_unique_id: "u", photo_file_id: "photo-large", media_kind: "photo",
        media_status: "ready", caption: caption)
    end
    assert_equal "pending", draft.status
    draft
  end

  test "fills the draft, counts the call and sends the review" do
    draft = start
    @reader.expects(:call).with("\xFF\xD8\xFFjpeg".b, caption: nil)
      .returns(Result.new(title: "Ботинки BOSS", price: BigDecimal("20990"), description: "Детали: размер 43"))

    assert_difference("AiCall.count") { PhotoGiftRecognitionJob.perform_now(draft.id, draft.version) }

    draft.reload
    assert_equal "ready", draft.status
    assert_equal({ "title" => "Ботинки BOSS", "price" => "20990.0", "description" => "Детали: размер 43" }, draft.fields)
    assert_equal 1, @sent.size
    assert_equal @owner.telegram_id, @sent.last[:chat_id]
    assert_includes @sent.last[:text], "Ботинки BOSS"
    assert_includes @sent.last[:text], "≈ 20"
    assert_equal 0, Item.count, "nothing is published before the person saves"
  end

  test "the person's caption wins over the model" do
    draft = start(caption: "Ботинки на зиму")
    @reader.expects(:call).with(anything, caption: "Ботинки на зиму")
      .returns(Result.new(title: "Ботинки BOSS", price: BigDecimal("20990"), description: nil))

    PhotoGiftRecognitionJob.perform_now(draft.id, draft.version)

    assert_equal "Ботинки на зиму", draft.reload.fields["title"]
    assert_equal "20990.0", draft.fields["price"]
  end

  test "a repeated job calls the model once" do
    draft = start
    version = draft.version
    @reader.expects(:call).once.returns(Result.new(title: "Лампа", price: nil, description: nil))

    PhotoGiftRecognitionJob.perform_now(draft.id, version)
    PhotoGiftRecognitionJob.perform_now(draft.id, version)

    assert_equal 1, @sent.size
  end

  test "a draft the person moved on from is left alone" do
    draft = start
    version = draft.version
    draft.manual!(expected_version: version)
    @reader.expects(:call).never
    @files.expects(:download).never

    assert_no_difference("AiCall.count") { PhotoGiftRecognitionJob.perform_now(draft.id, version) }
    assert_equal "ready", draft.reload.status
    assert_empty @sent
  end

  test "an edit during recognition beats the late result" do
    draft = start
    version = draft.version
    @reader.expects(:call).with do
      draft.update_field!("title", "Мой вариант", expected_version: draft.reload.version)
      true
    end.returns(Result.new(title: "Лампа", price: BigDecimal("100"), description: nil))

    PhotoGiftRecognitionJob.perform_now(draft.id, version)

    assert_equal({ "title" => "Мой вариант" }, draft.reload.fields)
    assert_empty @sent, "the person is already looking at their own edit"
  end

  test "the daily cap fails the draft into the manual review without downloading" do
    draft = start
    AiCall.stubs(:reserve!).returns(:user_limit)
    @files.expects(:download).never

    PhotoGiftRecognitionJob.perform_now(draft.id, draft.version)

    assert_equal [ "failed", "user_limit" ], [ draft.reload.status, draft.error_code ]
    assert_includes @sent.last[:text], I18n.t("bot.photo_gift.failed_limit")
  end

  test "model errors, empty pictures and broken downloads fail with a retry" do
    { YandexAi::Client::Error.new("timeout") => "timeout", nil => "no_product",
      Bot::TelegramFile::Error.new("too_large") => "file_too_large" }.each do |problem, code|
      draft = start
      if problem.is_a?(Bot::TelegramFile::Error)
        @files.stubs(:download).raises(problem)
      elsif problem
        @reader.stubs(:call).raises(problem)
      else
        @reader.stubs(:call).returns(nil)
      end

      PhotoGiftRecognitionJob.perform_now(draft.id, draft.version)

      assert_equal [ "failed", code ], [ draft.reload.status, draft.error_code ]
      assert_includes @sent.last[:text], I18n.t("bot.photo_gift.failed")
      buttons = @sent.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
      assert_includes buttons, "pg:r:#{draft.id}:#{draft.version}"
      @files.unstub(:download)
      @files.stubs(:download).returns("\xFF\xD8\xFFjpeg".b)
    end
  end

  test "a retry is read again" do
    draft = start
    @reader.stubs(:call).raises(YandexAi::Client::Error.new("timeout"))
    PhotoGiftRecognitionJob.perform_now(draft.id, draft.version)

    assert_enqueued_with(job: PhotoGiftRecognitionJob) { draft.reload.retry_recognition!(expected_version: draft.version) }
    @reader.stubs(:call).returns(Result.new(title: "Лампа", price: nil, description: nil))
    PhotoGiftRecognitionJob.perform_now(draft.id, draft.reload.version)
    assert_equal [ "ready", "Лампа" ], [ draft.reload.status, draft.fields["title"] ]
  end

  test "an undelivered review keeps the result" do
    draft = start
    @reader.stubs(:call).returns(Result.new(title: "Лампа", price: nil, description: nil))
    @api.stubs(:send_message).raises(Faraday::TimeoutError)

    PhotoGiftRecognitionJob.perform_now(draft.id, draft.version)
    assert_equal "ready", draft.reload.status
  end

  test "switching the feature off stops queued work" do
    draft = start
    ENV["PHOTO_GIFTS_ENABLED"] = "false"
    @reader.expects(:call).never
    PhotoGiftRecognitionJob.perform_now(draft.id, draft.version)
    assert_equal "pending", draft.reload.status
  end

  test "a stalled draft offers the manual review" do
    draft = start
    context = Object.new.extend(Bot::Helpers)
    presenter = -> { Bot::Presenters::PhotoGiftPresenter.new(draft, @owner, context) }
    assert_includes presenter.call.text, I18n.t("bot.photo_gift.recognizing")

    draft.update_column(:updated_at, 3.minutes.ago)
    assert_includes presenter.call.text, I18n.t("bot.photo_gift.review")
  end
end
