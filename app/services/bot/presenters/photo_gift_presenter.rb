module Bot
  module Presenters
    class PhotoGiftPresenter < BasePresenter
      object_name :draft
      FIELD_KEYS = { "t" => "title", "p" => "price", "d" => "description", "u" => "url" }.freeze

      def text
        return t("bot.photo_gift.unavailable") unless draft.editable?

        values = draft.fields
        lines = [ t("bot.photo_gift.review") ]
        lines << t("bot.photo_gift.routing_consent") unless draft.user.photo_ai_consented_at?
        lines << t("bot.photo_gift.failed") if draft.status == "failed"
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

        rows = [ [ button(t("bot.photo_gift.save", list: list_title.truncate(35)), "s", style: "primary") ] ]
        rows += FIELD_KEYS.map { |key, field| button(t("bot.fields.#{field}"), key) }.each_slice(2).to_a
        rows << [ button(t("bot.photo_gift.change_list"), "l") ]
        rows << [ button(t("bot.photo_gift.remove_photo"), "x") ] unless draft.result["without_photo"]
        rows << [ button(t("bot.photo_gift.retry"), "r") ] if draft.status == "failed" && !draft.result["retry_used"]
        rows << [ button(t("bot.photo_gift.later"), "z") ]
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

      def button(label, action, **options)
        context.inline_btn(label, "pg:#{action}:#{draft.id}:#{draft.version}", **options)
      end
    end
  end
end
