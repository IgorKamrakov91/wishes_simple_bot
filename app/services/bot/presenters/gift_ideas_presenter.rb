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
            mark = idea["item_id"].present? ? "✓ " : ""
            "#{index + 1}. #{mark}#{escape_html(idea.fetch('title'))}"
          end
          [ *ideas, "", I18n.t("bot.gift_ideas.ready_hint") ].join("\n")
        elsif suggestion.failed?
          I18n.t("bot.gift_ideas.failed")
        elsif %w[pending processing].include?(suggestion.status)
          I18n.t("bot.gift_ideas.waiting")
        else
          I18n.t("bot.gift_ideas.failed")
        end
        "#{heading}\n\n#{body}"
      end

      def keyboard
        rows = []
        if !expired? && suggestion.status == "ready"
          suggestion.ideas.each_with_index do |idea, index|
            label = idea.fetch("title").truncate(32)
            button = if idea["item_id"].present?
              inline_btn("✓ #{index + 1}. #{label}", "open_item:#{idea['item_id']}")
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

      def expired?
        suggestion.created_at < 2.days.ago
      end
    end
  end
end
