# frozen_string_literal: true

module Bot
  module Callbacks
    # "Continue input" and "Cancel input" on the help and settings screens
    class InputHandler < BaseHandler
      # Shows the question again with the draft as it is; once the input is
      # finished or cancelled the old button has nothing to bring back
      def resume
        prompt = InputPrompt.new(context)
        return prompt.render if prompt.active?

        context.notice = I18n.t("bot.commands.input_finished")
        WishlistHandler.new(context).main_menu
      end

      def cancel
        had_input = user.bot_state.present?
        user.clear_state!
        context.notice = I18n.t(had_input ? "bot.commands.cancelled" : "bot.commands.nothing_to_cancel")
        WishlistHandler.new(context).main_menu
      end
    end
  end
end
