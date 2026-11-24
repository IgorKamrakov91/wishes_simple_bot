require "test_helper"

class BotPhotoGiftHelpTest < ActiveSupport::TestCase
  setup { @flag = ENV["PHOTO_GIFTS_ENABLED"] }
  teardown { ENV["PHOTO_GIFTS_ENABLED"] = @flag }

  test "help explains what goes to Yandex only while photo gifts are on" do
    %i[ru en].each do |locale|
      I18n.with_locale(locale) do
        ENV["PHOTO_GIFTS_ENABLED"] = nil
        refute_includes Bot::Callbacks::HelpHandler.text, I18n.t("bot.photo_gift.help").lines.first.strip

        ENV["PHOTO_GIFTS_ENABLED"] = "true"
        text = Bot::Callbacks::HelpHandler.text
        assert_includes text, I18n.t("bot.photo_gift.help").rstrip
        assert text.index(I18n.t("bot.photo_gift.help").lines.first) < text.index("/start"), "before the command list"
        assert text.length < Bot::Context::MESSAGE_LIMIT - 200
      end
    end
  end
end
