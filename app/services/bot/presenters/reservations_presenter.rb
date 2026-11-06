# frozen_string_literal: true

module Bot
  module Presenters
    class ReservationsPresenter < BasePresenter
      PER_PAGE = 5
      TITLE_LIMIT = 28
      OWNER_LIMIT = 20
      LIST_LIMIT = 20

      attr_reader :page

      def self.scope_for(user)
        Item.accessible_to(user).where(reserved_by: user.telegram_id)
          .where.not(wishlist_id: user.wishlists.select(:id))
      end

      def self.page_for(item, user)
        scope_for(user).where("items.id < ?", item.id).count / PER_PAGE
      end

      def initialize(user, context, page: 0)
        super(self.class.scope_for(user), user, context)
        @total = model.count
        @page = page.clamp(0, total_pages - 1)
      end

      def text
        lines = [ "<b>#{t('bot.screens.reservations.title')}</b>" ]
        if @total.zero?
          lines << t("bot.screens.reservations.empty")
        else
          lines << t("bot.screens.reservations.hint")
          lines << t("bot.screens.collections.page", page: page + 1, total: total_pages) if total_pages > 1
        end
        lines.join("\n\n")
      end

      def keyboard
        # One button per gift, with whose list it is in; marking it bought
        # and releasing it are on the card
        rows = items.map do |item|
          [ context.inline_btn(item_label(item), "open_booked_item:#{item.id}:#{page}", style: "success") ]
        end
        rows << pager_row if pager_row.any?
        rows << [ context.inline_btn(t("bot.buttons.shared_lists"), "show_shared_lists") ]
        rows << [ context.inline_btn(t("bot.buttons.back_to_menu"), "main_menu") ]
        context.build_keyboard(rows)
      end

      private

      def item_label(item)
        wishlist = item.wishlist
        owner = wishlist.owner.first_name.presence || wishlist.owner.full_name
        # Buttons have one line and one font size, so the list follows the name
        label = +"#{item.title.to_s.truncate(TITLE_LIMIT)} · #{owner.to_s.truncate(OWNER_LIMIT)}, " \
                 "«#{wishlist.title.to_s.truncate(LIST_LIMIT)}»"
        label << " · #{t('bot.screens.reservations.purchased')}" if item.purchased?
        label
      end

      def total_pages
        [ (@total.to_f / PER_PAGE).ceil, 1 ].max
      end

      def items
        @items ||= model.order(:id).limit(PER_PAGE).offset(page * PER_PAGE).includes(wishlist: :user).to_a
      end

      def pager_row
        @pager_row ||= [
          (context.inline_btn(t("bot.buttons.prev_page"), "show_reservations:#{page - 1}") if page.positive?),
          (context.inline_btn(t("bot.buttons.next_page"), "show_reservations:#{page + 1}") if page < total_pages - 1)
        ].compact
      end
    end
  end
end
