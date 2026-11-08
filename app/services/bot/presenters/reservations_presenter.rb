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

      # Gifts still to buy come first, bought ones after; by id within each
      ORDER = Arel.sql("items.purchased_at IS NOT NULL, items.id")

      def self.page_for(item, user)
        scope = scope_for(user)
        before = if item.purchased?
          scope.where(purchased_at: nil).or(scope.where.not(purchased_at: nil).where("items.id < ?", item.id))
        else
          scope.where(purchased_at: nil).where("items.id < ?", item.id)
        end
        before.count / PER_PAGE
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
          lines << items.map { |item| entry(item) }.join("\n\n")
          lines << t("bot.screens.collections.page", page: page + 1, total: total_pages) if total_pages > 1
        end
        lines.join("\n\n")
      end

      def keyboard
        # One button per gift; marking it bought and releasing it are on the
        # card. Gifts still to buy are blue, bought ones plain with a ✓
        rows = items.map do |item|
          options = item.purchased? ? {} : { style: "primary" }
          [ context.inline_btn(item_label(item), "open_booked_item:#{item.id}:#{page}", **options) ]
        end
        rows << pager_row if pager_row.any?
        rows << [
          context.inline_btn(t("bot.buttons.back_to_menu"), "main_menu"),
          context.inline_btn(t("bot.buttons.shared_lists"), "show_shared_lists")
        ]
        context.build_keyboard(rows)
      end

      private

      # The text names the list; the button keeps the gift and its owner
      def entry(item)
        wishlist = item.wishlist
        key = item.purchased? ? "entry_purchased" : "entry"
        t("bot.screens.reservations.#{key}",
          title: escape_html(item.title.to_s.truncate(TITLE_LIMIT * 2)),
          price: (" · #{format_price(item.price)}" if item.price.present?),
          owner: escape_html(owner_name(wishlist).truncate(OWNER_LIMIT)),
          list: escape_html(wishlist.title.to_s.truncate(LIST_LIMIT * 2)))
      end

      def item_label(item)
        label = +(item.purchased? ? "✓ " : "★ ")
        label << "#{item.title.to_s.truncate(TITLE_LIMIT)} · #{owner_name(item.wishlist).truncate(OWNER_LIMIT)}"
        label << " · #{t('bot.screens.reservations.purchased')}" if item.purchased?
        label
      end

      def owner_name(wishlist)
        (wishlist.owner.first_name.presence || wishlist.owner.full_name).to_s
      end

      def total_pages
        [ (@total.to_f / PER_PAGE).ceil, 1 ].max
      end

      def items
        @items ||= model.order(ORDER).limit(PER_PAGE).offset(page * PER_PAGE).includes(wishlist: :user).to_a
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
