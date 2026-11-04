# frozen_string_literal: true

module Bot
  module Presenters
    class ListCollectionPresenter < BasePresenter
      PER_PAGE = 5

      attr_reader :page

      def self.scope_for(user, shared:)
        shared ? user.viewed_wishlists.distinct : user.wishlists
      end

      def self.back_callback(wishlist, user, shared:)
        index = scope_for(user, shared: shared).where("wishlists.id < ?", wishlist.id).count
        action = shared ? "show_shared_lists" : "show_lists"
        "#{action}:#{index / PER_PAGE}"
      end

      def initialize(user, context, shared: false, page: 0)
        super(self.class.scope_for(user, shared: shared), user, context)
        @shared = shared
        @total = model.count
        @page = page.clamp(0, total_pages - 1)
      end

      def text
        lines = [ "<b>#{t("bot.buttons.#{screen}")}</b>" ]
        lines << if @total.zero?
          t("bot.screens.#{screen}.empty")
        else
          [ t("bot.screens.collections.choose"),
            t("bot.screens.collections.page", page: page + 1, total: total_pages) ].join("\n")
        end
        lines.join("\n\n")
      end

      def keyboard
        rows = lists.map { |list| [ context.inline_btn(label(list), "open_list:#{list.id}") ] }
        rows << pager_row if pager_row.any?
        unless @shared
          rows << [ context.inline_btn(t("bot.buttons.create_list"), "new_list", style: "primary") ]
        end
        rows << [ context.inline_btn(t("bot.buttons.back_to_menu"), "main_menu") ]
        context.build_keyboard(rows)
      end

      private

      def screen
        @shared ? "shared_lists" : "my_lists"
      end

      def total_pages
        [ (@total.to_f / PER_PAGE).ceil, 1 ].max
      end

      def lists
        @lists ||= model.order(:id).limit(PER_PAGE).offset(page * PER_PAGE).includes(:user).to_a
      end

      def item_counts
        @item_counts ||= Item.where(wishlist_id: lists.map(&:id)).group(:wishlist_id).count
      end

      def label(list)
        title = list.title.to_s.truncate(@shared ? 30 : 40)
        if @shared
          owner = (list.owner.first_name.presence || list.owner.full_name).to_s.truncate(18)
          title = "#{owner} · #{title}"
        end
        "#{title} · #{t('bot.inline.gifts', count: item_counts.fetch(list.id, 0))}"
      end

      def pager_row
        action = @shared ? "show_shared_lists" : "show_lists"
        @pager_row ||= [
          (context.inline_btn(t("bot.buttons.prev_page"), "#{action}:#{page - 1}") if page.positive?),
          (context.inline_btn(t("bot.buttons.next_page"), "#{action}:#{page + 1}") if page < total_pages - 1)
        ].compact
      end
    end
  end
end
