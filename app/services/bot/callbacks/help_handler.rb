# frozen_string_literal: true

module Bot
  module Callbacks
    # Help keeps the pending input: people look things up in the middle of
    # typing and then carry on
    class HelpHandler < BaseHandler
      def self.text
        [
          I18n.t("bot.commands.help").rstrip,
          Profile.command_list,
          I18n.t("bot.commands.help_cancel"),
          "",
          I18n.t("bot.commands.help_contact")
        ].join("\n")
      end

      def show_help
        prompt = InputPrompt.new(context)
        rows = prompt.resume_rows
        rows << [
          context.inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu"),
          context.inline_btn(I18n.t("bot.buttons.settings"), "settings")
        ]
        context.render(prompt.with_input_note(self.class.text), context.build_keyboard(rows))
      end
    end
  end
end
