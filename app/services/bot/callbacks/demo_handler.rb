# frozen_string_literal: true

module Bot
  module Callbacks
    # "How it looks": a friend's list made of fixed texts, where a newcomer
    # can try a reservation. Nothing is saved and nobody is notified; which
    # gift is "reserved" travels in the button itself.
    class DemoHandler < BaseHandler
      def show(mine = nil)
        gifts = I18n.t("bot.demo.gifts")
        mine = nil unless mine.is_a?(Integer) && mine.between?(0, gifts.size - 1) && !taken?(mine)
        context.render(text(gifts, mine), keyboard(gifts, mine))
      end

      def taken
        context.notice = I18n.t("bot.demo.taken_notice")
      end

      private

      TAKEN = 1

      def taken?(index)
        index == TAKEN
      end

      def text(gifts, mine)
        reserved = mine ? 2 : 1
        lines = [ "<i>#{I18n.t('bot.demo.intro')}</i>",
                  [ I18n.t("bot.screens.list.shared_by", owner: I18n.t("bot.demo.owner")),
                    "🎁 <b>#{I18n.t('bot.demo.title')}</b>",
                    I18n.t("bot.screens.list.progress", reserved: reserved, total: gifts.size) ].join("\n"),
                  I18n.t("bot.screens.list.legend") ]
        lines << (mine ? I18n.t("bot.demo.reserved", title: gifts[mine], owner: I18n.t("bot.demo.owner")) : I18n.t("bot.demo.try"))
        lines.join("\n\n")
      end

      def keyboard(gifts, mine)
        rows = gifts.each_with_index.map do |title, index|
          if taken?(index)
            [ context.inline_btn("✓ #{title}", "demo_taken") ]
          elsif index == mine
            [ context.inline_btn("★ #{title}", "demo", style: Presenters::WishlistPresenter::MY_RESERVATION_STYLE) ]
          else
            [ context.inline_btn(title, "demo:#{index}") ]
          end
        end
        rows << [ context.inline_btn(I18n.t("bot.demo.create_own"), "new_list", style: "primary") ]
        # Leaving the demo goes back to an unfinished input, if there is one
        back = InputPrompt.new(context).active? ? "resume_input" : "main_menu"
        rows << [ context.inline_btn(I18n.t("bot.buttons.back"), back) ]
        context.build_keyboard(rows)
      end
    end
  end
end
