# frozen_string_literal: true

module Bot
  module Callbacks
    class SettingsHandler < BaseHandler
      SETTINGS = %w[notify_own_reservations notify_friend_reservations].freeze

      def show_settings
        # Each button writes the value it shows next, so a repeated delivery
        # of the same press can't flip the choice back
        rows = SETTINGS.map do |setting|
          enabled = user.public_send(setting)
          state = I18n.t(enabled ? "bot.screens.settings.on" : "bot.screens.settings.off")
          [ context.inline_btn(I18n.t("bot.screens.settings.#{setting}", state: state),
                              "set_setting:#{setting}:#{enabled ? 0 : 1}") ]
        end
        rows << [ context.inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ]

        context.render(I18n.t("bot.screens.settings.text"), context.build_keyboard(rows))
      end

      def set_setting(setting, value)
        return show_settings unless SETTINGS.include?(setting)

        enabled = value == 1
        user.update!(setting => enabled)
        context.notice = I18n.t(enabled ? "bot.screens.settings.turned_on" : "bot.screens.settings.turned_off",
                               list_scope: I18n.t("bot.screens.settings.scopes.#{setting}"))
        show_settings
      end
    end
  end
end
