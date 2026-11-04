# frozen_string_literal: true

module Bot
  module Callbacks
    class SettingsHandler < BaseHandler
      SETTINGS = %w[notify_own_reservations notify_friend_reservations].freeze

      def show_settings
        rows = SETTINGS.map do |setting|
          state = I18n.t(user.public_send(setting) ? "bot.screens.settings.on" : "bot.screens.settings.off")
          [ context.inline_btn(I18n.t("bot.screens.settings.#{setting}", state: state), "toggle_setting:#{setting}") ]
        end
        rows << [ context.inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ]

        context.render(I18n.t("bot.screens.settings.text"), context.build_keyboard(rows))
      end

      def toggle_setting(setting)
        return show_settings unless SETTINGS.include?(setting)

        user.update!(setting => !user.public_send(setting))
        context.notice = I18n.t(user.public_send(setting) ? "bot.screens.settings.turned_on" : "bot.screens.settings.turned_off")
        show_settings
      end
    end
  end
end
