require "test_helper"
require "mocha/minitest"

class BotProfileTest < ActiveSupport::TestCase
  test "sets Russian texts for everyone and removes the English ones" do
    api = mock("TelegramApi")
    calls = []
    %i[set_my_commands set_my_description set_my_short_description delete_my_commands].each do |method|
      api.stubs(method).with { |params| calls << [ method, params ]; true }
    end

    I18n.with_locale(:en) { Bot::Profile.apply(api) }

    default = calls.reject { |_, params| params.key?(:language_code) }.to_h
    assert_equal %w[start my new cancel help], default[:set_my_commands][:commands].map { |c| c[:command] }
    assert_equal "Главное меню", default[:set_my_commands][:commands].first[:description]
    assert_match "Вишлисты", default[:set_my_short_description][:short_description]

    english = calls.select { |_, params| params[:language_code] == "en" }.to_h
    assert english.key?(:delete_my_commands)
    assert_equal "", english[:set_my_description][:description]
    assert_equal "", english[:set_my_short_description][:short_description]
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
