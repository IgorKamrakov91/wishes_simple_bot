module Bot
  module Presenters
    # The evening digest of photo drafts left in the inbox
    class PhotoInboxDigestPresenter < BasePresenter
      object_name :drafts
      SHOWN = 10

      def text
        lines = drafts.first(SHOWN).map { |draft| "• #{line(draft)}" }
        lines << t("bot.photo_inbox.more", count: drafts.size - SHOWN) if drafts.size > SHOWN
        parts = [ t("bot.photo_inbox.digest", count: drafts.size), lines.join("\n") ]
        parts << t("bot.photo_inbox.needs_consent") if needs_consent?
        parts.join("\n\n")
      end

      def keyboard
        rows = []
        rows << [ context.inline_btn(t("bot.photo_inbox.allow"), "pgd:c") ] if needs_consent?
        if self.class.savable(drafts).any?
          list = user.wishlists.order(updated_at: :desc, id: :desc).first
          title = list&.title || t("bot.photo_gift.default_list")
          rows << [ context.inline_btn(t("bot.photo_inbox.save_all", list: title.truncate(35)), "pgd:s:#{list&.id || 0}") ]
        end
        rows << [ context.inline_btn(t("bot.photo_inbox.one_by_one"), "pgi:0") ]
        context.build_keyboard(rows)
      end

      # Drafts that already have a name and can be saved without questions
      def self.savable(drafts)
        drafts.select { |draft| %w[ready failed].include?(draft.status) && draft.fields["title"].present? }
      end

      private

      def needs_consent?
        user.photo_ai_consented_at.nil? && drafts.any? { |draft| draft.status == "awaiting_consent" }
      end

      def line(draft)
        title = draft.fields["title"]
        return t("bot.photo_inbox.unnamed") if title.blank?

        price = draft.fields["price"]
        price.present? ? "#{escape_html(title)} — ≈ #{format_price(price)}" : escape_html(title)
      end
    end
  end
end
