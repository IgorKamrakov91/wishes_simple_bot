require "test_helper"
require "mocha/minitest"

class BotProfileTest < ActiveSupport::TestCase
  test "sets Russian texts by default and English ones for English users" do
    api = mock("TelegramApi")
    calls = []
    %i[set_my_commands set_my_description set_my_short_description].each do |method|
      api.stubs(method).with { |params| calls << [ method, params ]; true }
    end

    Bot::Profile.apply(api)

    default_commands = calls.find { |method, params| method == :set_my_commands && !params.key?(:language_code) }.last
    assert_equal %w[start my new cancel help], default_commands[:commands].map { |c| c[:command] }
    assert_equal "Главное меню", default_commands[:commands].first[:description]

    english = calls.select { |_, params| params[:language_code] == "en" }.to_h
    assert_equal "Main menu", english[:set_my_commands][:commands].first[:description]
    assert_match "Wishlists", english[:set_my_short_description][:short_description]
  end

  test "texts fit Telegram's limits" do
    %i[ru en].each do |locale|
      I18n.with_locale(locale) do
        assert_operator I18n.t("bot.profile.description").length, :<=, 512
        assert_operator I18n.t("bot.profile.short_description").length, :<=, 120
        Bot::Profile.commands.each do |command|
          assert_match(/\A[a-z0-9_]{1,32}\z/, command[:command])
          assert_includes 1..256, command[:description].length
        end
      end
    end
  end

  test "every command in the menu is one the bot understands" do
    handled = File.read(Rails.root.join("app/services/bot/commands.rb")).scan(%r{when "/(\w+)"}).flatten
    assert_empty Bot::Profile::COMMANDS - handled
  end
end
