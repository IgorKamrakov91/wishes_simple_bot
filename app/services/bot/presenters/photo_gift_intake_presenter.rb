module Bot
  module Presenters
    class PhotoGiftIntakePresenter < BasePresenter
      object_name :draft

      def text
        lines = [ t("bot.photo_gift.received") ]
        lines << t("bot.photo_gift.routing_consent") unless draft.user.photo_ai_consented_at?
        lines.join("\n\n")
      end

      def keyboard
        lists = user.wishlists.order(updated_at: :desc, id: :desc).limit(3)
        rows = lists.map do |list|
          [ context.inline_btn(t("bot.photo_gift.to_list", list: list.title.truncate(40)),
              "pgw:#{draft.id}:#{draft.version}:#{list.id}") ]
        end
        if lists.empty?
          rows << [ context.inline_btn(t("bot.photo_gift.to_list", list: t("bot.photo_gift.default_list")),
            "pgw:#{draft.id}:#{draft.version}:0") ]
        elsif lists.size > 1
          rows << [ context.inline_btn(t("bot.photo_gift.other_lists"), "pgl:#{draft.id}:#{draft.version}:0") ]
        end
        rows << [ context.inline_btn(t("bot.photo_gift.later"), "pg:z:#{draft.id}:#{draft.version}") ]
        context.build_keyboard(rows)
      end
    end
  end
end
