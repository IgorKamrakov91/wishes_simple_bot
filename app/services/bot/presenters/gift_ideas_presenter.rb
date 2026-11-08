# frozen_string_literal: true

module Bot
  module Presenters
    # Used by both the background job and callbacks, without a live Context.
    class GiftIdeasPresenter
      include Helpers

      attr_reader :suggestion

      def initialize(suggestion)
        @suggestion = suggestion
      end

      # Plain search links; opening them costs nothing and never calls Yandex AI.
      SEARCH_URLS = {
        market: "https://market.yandex.ru/search?text=%s",
        ozon: "https://www.ozon.ru/search/?text=%s",
        wildberries: "https://www.wildberries.ru/catalog/0/search.aspx?search=%s"
      }.freeze

      def self.search_url(store, title)
        format(SEARCH_URLS.fetch(store), CGI.escape(title.to_s))
      end

      def text
        heading = I18n.t("bot.gift_ideas.heading", list: escape_html(suggestion.wishlist.title.to_s.truncate(100)))
        body = if expired?
          I18n.t("bot.gift_ideas.expired")
        elsif suggestion.status == "ready" && suggestion.ideas.present?
          ideas = suggestion.ideas.each_with_index.map do |idea, index|
            title = escape_html(idea.fetch("title"))
            title = if linked_item?(idea)
              "✓ #{title}"
            elsif idea["item_id"].present?
              I18n.t("bot.gift_ideas.deleted_title", title: title)
            else
              title
            end
            "#{index + 1}. #{title}"
          end
          [ *ideas, "", I18n.t("bot.gift_ideas.ready_hint") ].join("\n")
        elsif suggestion.failed?
          failure_text
        elsif %w[pending processing].include?(suggestion.status)
          I18n.t("bot.gift_ideas.waiting")
        else
          failure_text
        end
        "#{heading}\n\n#{body}"
      end

      def keyboard
        rows = []
        if !expired? && suggestion.status == "ready"
          suggestion.ideas.each_with_index do |idea, index|
            label = idea.fetch("title").truncate(32)
            button = if linked_item?(idea)
              inline_btn("✓ #{index + 1}. #{label}", "open_item:#{idea['item_id']}")
            elsif idea["item_id"].present?
              inline_btn(I18n.t("bot.gift_ideas.deleted_button", number: index + 1, title: label), "show_gift_ideas:#{suggestion.id}")
            else
              inline_btn("+ #{index + 1}. #{label}", "add_idea:#{suggestion.id}:#{index}")
            end
            rows << [ button ]
          end
        end
        rows << [ inline_btn(I18n.t("bot.buttons.back_to_list"), "open_list:#{suggestion.wishlist_id}") ]
        build_keyboard(rows)
      end

      private

      def linked_item?(idea)
        linked_item_ids.include?(idea["item_id"])
      end

      def linked_item_ids
        @linked_item_ids ||= suggestion.wishlist.items.where(id: suggestion.ideas.filter_map { |idea| idea["item_id"] }).pluck(:id).to_set
      end

      def failure_text
        kind = case suggestion.error_code
        when "no_ideas" then "no_ideas"
        when "disabled" then "disabled"
        else "technical"
        end
        I18n.t("bot.gift_ideas.failed.#{kind}")
      end

      def expired?
        suggestion.created_at < GiftSuggestion::OPEN_FOR.ago
      end
    end
  end
end
