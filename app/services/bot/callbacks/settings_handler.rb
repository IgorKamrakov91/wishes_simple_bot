# frozen_string_literal: true

module Bot
  module Callbacks
    class SettingsHandler < BaseHandler
      SETTINGS = %w[notify_own_reservations notify_friend_reservations notify_birthdays].freeze

      def show_settings
        # Each button writes the value it shows next, so a repeated delivery
        # of the same press can't flip the choice back
        rows = SETTINGS.map do |setting|
          enabled = user.public_send(setting)
          state = I18n.t(enabled ? "bot.screens.settings.on" : "bot.screens.settings.off")
          [ context.inline_btn(I18n.t("bot.screens.settings.#{setting}", state: state),
                              "set_setting:#{setting}:#{enabled ? 0 : 1}") ]
        end
        rows << [ context.inline_btn(I18n.t("bot.screens.reservation_reminders.button", frequency: reminder_frequency), "reservation_reminders") ]
        prompt = InputPrompt.new(context)
        rows.concat(prompt.resume_rows)
        rows << [ context.inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ]

        context.render(prompt.with_input_note(I18n.t("bot.screens.settings.text")), context.build_keyboard(rows))
      end

      def set_setting(setting, value)
        return show_settings unless SETTINGS.include?(setting)

        enabled = value == 1
        user.update!(setting => enabled)
        UpdateDelivery.record_result("settings_updated")
        context.notice = I18n.t(enabled ? "bot.screens.settings.turned_on" : "bot.screens.settings.turned_off",
                               list_scope: I18n.t("bot.screens.settings.scopes.#{setting}"))
        show_settings
      end

      def show_reservation_reminders
        rows = User::RESERVATION_REMINDER_DAYS.map do |days|
          label = reminder_frequency(days)
          label = "✓ #{label}" if user.reservation_reminder_days == days
          [ context.inline_btn(label, "set_reminder_days:#{days}") ]
        end
        prompt = InputPrompt.new(context)
        rows.concat(prompt.resume_rows)
        rows << [ context.inline_btn(I18n.t("bot.buttons.settings"), "settings") ]
        context.render(prompt.with_input_note(I18n.t("bot.screens.reservation_reminders.text")), context.build_keyboard(rows))
      end

      def set_reminder_days(days)
        user.configure_reservation_reminders!(days)
        UpdateDelivery.record_result("reminder_updated")
        context.notice = I18n.t("bot.screens.reservation_reminders.updated", frequency: reminder_frequency)
        show_reservation_reminders
      end

      private

      def reminder_frequency(days = user.reservation_reminder_days)
        if days.zero?
          I18n.t("bot.screens.reservation_reminders.off")
        else
          I18n.t("bot.screens.reservation_reminders.every", count: days)
        end
      end
    end
  end
end
