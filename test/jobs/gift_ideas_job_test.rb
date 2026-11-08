require "test_helper"
require "mocha/minitest"

class GiftIdeasJobTest < ActiveJob::TestCase
  class FakePresenter
    def initialize(suggestion)
      @suggestion = suggestion
    end

    def text
      @suggestion.ready? ? @suggestion.titles.join(", ") : "failed"
    end

    def keyboard
      nil
    end
  end

  setup do
    @defined_presenter = Bot::Presenters.const_defined?(:GiftIdeasPresenter, false)
    Bot::Presenters.const_set(:GiftIdeasPresenter, FakePresenter) unless @defined_presenter
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["TELEGRAM_BOT_TOKEN"] = "token"
    GiftSuggestion.stubs(:enabled?).returns(true)
    @ideas = mock("GiftIdeas")
    YandexAi::GiftIdeas.stubs(:new).returns(@ideas)
    @owner = User.create!(telegram_id: 97101, first_name: "Owner")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.items.create!(title: "Плед")
    @suggestion = GiftSuggestion.create!(user: @owner, wishlist: @wishlist)
    @api = mock("TelegramApi")
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
    Bot::Presenters.send(:remove_const, :GiftIdeasPresenter) unless @defined_presenter
  end

  test "saves ideas before sending them to the owner" do
    @ideas.expects(:call).with("Birthday", [ "Плед" ]).returns([ "Лампа", "Кружка" ])
    @api.expects(:send_message).with { |params| params[:chat_id] == 97101 && @suggestion.reload.ready? }

    GiftIdeasJob.perform_now(@suggestion.id)

    assert_equal [ "Лампа", "Кружка" ], @suggestion.reload.titles
  end

  test "a model error is saved as a code and the owner is told" do
    @ideas.expects(:call).raises(YandexAi::Client::Error.new("timeout"))
    @api.expects(:send_message)

    GiftIdeasJob.perform_now(@suggestion.id)

    assert_equal [ "failed", "timeout" ], [ @suggestion.reload.status, @suggestion.error_code ]
  end

  test "a repeated job and a failed delivery never ask the model again" do
    @ideas.expects(:call).once.returns([ "Лампа" ])
    @api.expects(:send_message).once.raises(Faraday::TimeoutError)

    GiftIdeasJob.perform_now(@suggestion.id)
    GiftIdeasJob.perform_now(@suggestion.id)

    assert @suggestion.reload.ready?
    assert_equal [ "Лампа" ], @suggestion.titles
  end

  test "a request queued before the switch was turned off doesn't call the model" do
    GiftSuggestion.stubs(:enabled?).returns(false)
    @ideas.expects(:call).never
    @api.expects(:send_message).with do |params|
      params[:chat_id] == @owner.telegram_id && @suggestion.reload.failed?
    end

    GiftIdeasJob.perform_now(@suggestion.id)

    assert_equal [ "failed", "disabled" ], [ @suggestion.reload.status, @suggestion.error_code ]
  end

  test "logs no titles or ideas" do
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    @ideas.stubs(:call).returns([ "СЕКРЕТНАЯ_ИДЕЯ" ])
    @api.stubs(:send_message)

    GiftIdeasJob.perform_now(@suggestion.id)

    refute_includes output.string, "СЕКРЕТНАЯ_ИДЕЯ"
    refute_includes output.string, "Birthday"
  ensure
    Rails.logger = previous
  end
end
