module Bot
  module Presenters
    class PhotoGiftPresenter < BasePresenter
      object_name :draft
      # :edit shows the field buttons instead of the main ones
      attr_accessor :menu
      FIELD_KEYS = { "t" => "title", "p" => "price", "d" => "description", "u" => "url" }.freeze

      # The card: name, price with the main details, and one line on what
      # happens; empty fields and field labels are left out
      def text
        return t("bot.photo_gift.unavailable") unless draft.editable?
        return t("bot.photo_gift.recognizing") if recognizing?

        values = draft.fields
        title = values["title"].presence
        head = title ? "🎁 <b>#{escape_html(title)}</b>" : "🎁 #{t("bot.photo_gift.no_name")}"
        facts = [ ("≈ #{format_price(values["price"])}" if values["price"].present?), summary(values["description"]) ].compact
        card = [ head, facts.join(" · ").presence, (link_line(values["url"]) if values["url"].present?) ].compact.join("\n")

        notes = []
        # Said once, on the first photo; /help keeps it for later
        unless draft.user.photo_ai_consented_at?
          notes << t("bot.photo_gift.routing_consent")
          notes << t("bot.photo_gift.photo_public") unless draft.result["without_photo"]
        end
        if draft.status == "failed"
          notes << t(draft.error_code.in?(%w[limit user_limit disabled]) ? "bot.photo_gift.failed_limit" : "bot.photo_gift.failed")
        end
        notes << t("bot.photo_gift.card_hint", list: escape_html(list_title))
        notes << t("bot.photo_gift.without_photo_note") if draft.result["without_photo"]
        notes << t("bot.photo_gift.preparing") if draft.media_status.in?(%w[pending processing]) && !draft.result["without_photo"]
        notes << t("bot.photo_gift.media_failed") if draft.media_status == "failed" && !draft.result["without_photo"]
        notes << t("bot.photo_gift.edit_hint") if menu == :edit
        [ card, notes.join("\n") ].join("\n\n")
      end

      def keyboard
        return context.build_keyboard([]) unless draft.editable?
        return context.build_keyboard(edit_rows) if menu == :edit

        if recognizing?
          rows = [ [ button(t("bot.photo_gift.manual"), "m") ] ]
        else
          rows = [ [ button(t("bot.photo_gift.save", list: list_title.truncate(35)), "s", style: "primary") ] ]
          rows << [ button(t("bot.photo_gift.edit"), "e"), button(t("bot.photo_gift.change_list"), "l") ]
          rows << [ button(t("bot.photo_gift.retry"), "r") ] if draft.status == "failed" && !draft.result["retry_used"]
        end
        rows << [ button(t("bot.photo_gift.later"), "z"), button(t("bot.photo_gift.cancel_short"), "c") ]
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

      def edit_rows
        rows = FIELD_KEYS.map { |key, field| button(t("bot.fields.#{field}"), key) }.each_slice(2).to_a
        rows << [ button(t("bot.photo_gift.remove_photo"), "x") ] unless draft.result["without_photo"]
        rows << [ context.inline_btn(t("bot.buttons.back"), "pgb:#{draft.id}") ]
        rows
      end

      # The first line of the description, without its "Details:" label
      def summary(description)
        line = description.to_s.lines.first.to_s.strip.sub(/\A[[:alpha:] ]{1,20}:\s*/, "")
        escape_html(line.truncate(160)) if line.present?
      end

      def link_line(url)
        host = Item.web_uri(url)&.host&.delete_prefix("www.")
        "🔗 #{escape_html(host || url.truncate(60))}"
      end

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
