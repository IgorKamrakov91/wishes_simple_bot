module Bot
  module Presenters
    class PhotoGiftPresenter < BasePresenter
      object_name :draft
      FIELD_KEYS = { "t" => "title", "p" => "price", "d" => "description", "u" => "url" }.freeze

      def text
        return t("bot.photo_gift.unavailable") unless draft.editable?
        return t("bot.photo_gift.consent") if draft.status == "awaiting_consent"
        return t("bot.photo_gift.recognizing") if recognizing?

        values = draft.fields
        lines = [ t("bot.photo_gift.review") ]
        if draft.status == "failed"
          lines << t(draft.error_code.in?(%w[limit user_limit disabled]) ? "bot.photo_gift.failed_limit" : "bot.photo_gift.failed")
        end
        FIELD_KEYS.values.each do |field|
          value = values[field]
          value = "≈ #{format_price(value)}" if field == "price" && value.present?
          shown = value.present? ? value.to_s.truncate(field == "url" ? 250 : Item::DESCRIPTION_LIMIT) : t("bot.photo_gift.empty")
          lines << "<b>#{t("bot.fields.#{field}")}:</b> #{escape_html(shown)}"
        end
        lines << t("bot.photo_gift.target", list: escape_html(list_title))
        lines << t("bot.photo_gift.check")
        lines << t("bot.photo_gift.photo_public") unless draft.result["without_photo"]
        lines << t("bot.photo_gift.preparing") if draft.media_status.in?(%w[pending processing]) && !draft.result["without_photo"]
        lines << t("bot.photo_gift.media_failed") if draft.media_status == "failed" && !draft.result["without_photo"]
        lines.join("\n\n")
      end

      def keyboard
        return context.build_keyboard([]) unless draft.editable?

        if draft.status == "awaiting_consent"
          rows = [ [ button(t("bot.photo_gift.recognize"), "a"), button(t("bot.photo_gift.manual"), "m") ] ]
        elsif recognizing?
          rows = [ [ button(t("bot.photo_gift.manual"), "m") ] ]
        else
          rows = [ [ button(t("bot.photo_gift.save", list: list_title.truncate(35)), "s", style: "primary") ] ]
          rows += FIELD_KEYS.map { |key, field| button(t("bot.fields.#{field}"), key) }.each_slice(2).to_a
          rows << [ button(t("bot.photo_gift.change_list"), "l") ]
          rows << [ button(t("bot.photo_gift.remove_photo"), "x") ] unless draft.result["without_photo"]
          rows << [ button(t("bot.photo_gift.retry"), "r") ] if draft.status == "failed" && !draft.result["retry_used"]
        end
        rows << [ button(t("bot.buttons.cancel"), "c") ]
        context.build_keyboard(rows)
      end

      def list_title
        if draft.result["new_list"]
          t("bot.photo_gift.new_list", list: t("bot.photo_gift.default_list", locale: draft.locale))
        else
          draft.wishlist&.title || t("bot.photo_gift.missing_list")
        end
      end

      private

      # A lost job leaves the draft pending; after the deadline the person
      # gets the manual review instead of waiting forever
      def recognizing?
        draft.status == "pending" && !draft.recognition_stalled?
      end

      def button(label, action, **options)
        context.inline_btn(label, "pg:#{action}:#{draft.id}:#{draft.version}", **options)
      end
    end
  end
end
