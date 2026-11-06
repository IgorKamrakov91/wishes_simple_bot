# frozen_string_literal: true

module Bot
  module Presenters
    class ItemPresenter < BasePresenter
      object_name :item

      def initialize(item, user, context, reservations_page: nil)
        super(item, user, context)
        @reservations_page = reservations_page
      end

      def text
        blocks = [ heading ]
        blocks << details if details.present?
        blocks << guest_status unless owner?
        blocks.join("\n\n")
      end

      def keyboard
        context.build_keyboard(buttons)
      end

      # Shows the shop's preview (title and photo) under the card
      def link_preview_options
        return no_link_preview unless web_url

        Telegram::Bot::Types::LinkPreviewOptions.new(url: web_url.to_s, prefer_large_media: true)
      end

      private

      def heading
        lines = []
        lines << "<i>#{escape_html(wishlist.title)} · #{t('bot.screens.item.position', index: position + 1, total: item_ids.size)}</i>"
        lines << "<b>#{escape_html(item.title)}</b>"
        lines << "<i>#{escape_html(item.description)}</i>" if item.description.present?
        lines.join("\n")
      end

      def details
        @details ||= begin
          lines = []
          lines << "#{t('bot.screens.item.price')}: <b>#{format_price(item.price)}</b>" if item.price.present?
          lines << "#{t('bot.screens.item.store')}: #{store_link}" if item.url.present?
          lines << "#{t('bot.screens.item.status')}: #{owner_status}" if owner?
          lines.join("\n")
        end
      end

      def store_link
        return escape_html(item.url) unless web_url

        "<a href=\"#{escape_html(web_url.to_s)}\">#{escape_html(web_url.host.delete_prefix('www.'))}</a>"
      end

      # The owner never learns who reserved the gift
      def owner_status
        item.reserved? ? t("bot.screens.item.owner_reserved") : t("bot.screens.item.owner_free")
      end

      def guest_status
        if !item.reserved?
          t("bot.screens.item.guest_free", owner: escape_html(wishlist.owner.first_name.presence || wishlist.owner.full_name))
        elsif reserved_by_me?
          t("bot.screens.item.guest_mine")
        else
          t("bot.screens.item.guest_taken", user: "<tg-spoiler>#{escape_html(reserver_label)}</tg-spoiler>")
        end
      end

      def reserver_label
        reserver = item.reserver
        return t("bot.presenters.item.unknown_reserver") unless reserver

        reserver.username.present? ? "@#{reserver.username}" : reserver.full_name
      end

      def buttons
        buttons = []

        unless owner?
          if !item.reserved?
            buttons << [ context.inline_btn(t("bot.buttons.reserve"), "reserve_item:#{item.id}:#{item.reservation_version}", style: "success") ]
          elsif reserved_by_me?
            release = if @reservations_page
              "release_book:#{item.id}:#{item.reservation_version}:#{@reservations_page}"
            else
              "unreserve_item:#{item.id}:#{item.reservation_version}"
            end
            buttons << [ context.inline_btn(t("bot.buttons.unreserve"), release) ]
          end
        end

        buttons << [ context.inline_btn(t("bot.buttons.open_in_store"), url: web_url.to_s) ] if web_url

        if owner?
          buttons << [
            context.inline_btn(t("bot.buttons.edit"), "edit_item:#{item.id}"),
            context.inline_btn(t("bot.buttons.delete"), "confirm_delete_item:#{item.id}", style: "danger")
          ]
        end

        buttons << neighbours_row if @reservations_page.nil? && neighbours_row.any?
        buttons << [ context.inline_btn(t("bot.buttons.back_to_list"), "list_page:#{wishlist.id}:#{WishlistPresenter.page_of(position)}") ]
        if @reservations_page
          buttons << [ context.inline_btn(t("bot.screens.reservations.back"), "show_reservations:#{@reservations_page}") ]
        elsif !owner? && (reserved_by_me? || ReservationsPresenter.scope_for(user).exists?)
          page = reserved_by_me? ? ReservationsPresenter.page_for(item, user) : 0
          buttons << [ context.inline_btn(t("bot.screens.reservations.back"), "show_reservations:#{page}") ]
        end
        buttons
      end

      # Previous and next gifts with words, and no placeholder buttons
      def neighbours_row
        @neighbours_row ||= begin
          previous_id = item_ids[position - 1] if position.positive?
          next_id = item_ids[position + 1]
          [
            (context.inline_btn(t("bot.buttons.prev_item"), "open_item:#{previous_id}") if previous_id),
            (context.inline_btn(t("bot.buttons.next_item"), "open_item:#{next_id}") if next_id)
          ].compact
        end
      end

      # Only http(s) links can go into a URL button, anything else is shown as text
      def web_url
        return @web_url if defined?(@web_url)

        @web_url = item.web_uri
      end

      def wishlist
        item.wishlist
      end

      def item_ids
        @item_ids ||= wishlist.items.pluck(:id)
      end

      def position
        item_ids.index(item.id) || 0
      end

      def reserved_by_me?
        item.reserved_by?(user)
      end

      def owner?
        wishlist.user_id == user.id
      end

      def reserver_label
        reserver = item.reserver
        return I18n.t("bot.presenters.item.unknown_reserver") unless reserver

        reserver.username.present? ? "@#{reserver.username}" : reserver.full_name
      end
    end
  end
end
