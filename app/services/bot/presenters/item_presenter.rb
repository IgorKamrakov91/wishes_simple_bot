# frozen_string_literal: true

module Bot
  module Presenters
    class ItemPresenter < BasePresenter
      object_name :item

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

        Telegram::Bot::Types::LinkPreviewOptions.new(url: item.url, prefer_large_media: true)
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

        "<a href=\"#{escape_html(item.url)}\">#{escape_html(web_url.host.delete_prefix('www.'))}</a>"
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
        reserver&.username ? "@#{reserver.username}" : reserver&.first_name
      end

      def buttons
        buttons = []

        unless owner?
          if !item.reserved?
            buttons << [ context.inline_btn(t("bot.buttons.reserve"), "toggle_reserve:#{item.id}") ]
          elsif reserved_by_me?
            buttons << [ context.inline_btn(t("bot.buttons.unreserve"), "toggle_reserve:#{item.id}") ]
          end
        end

        buttons << [ context.inline_btn(t("bot.buttons.open_in_store"), url: item.url) ] if web_url

        if owner?
          buttons << [
            context.inline_btn(t("bot.buttons.edit"), "edit_item:#{item.id}"),
            context.inline_btn(t("bot.buttons.delete"), "confirm_delete_item:#{item.id}")
          ]
        end

        buttons << navigation_row
        buttons
      end

      def navigation_row
        back = context.inline_btn(t("bot.buttons.back_to_list"), "list_page:#{wishlist.id}:#{WishlistPresenter.page_of(position)}")
        return [ back ] if item_ids.size < 2

        previous_id = item_ids[position - 1] if position.positive?
        next_id = item_ids[position + 1]

        [
          previous_id ? context.inline_btn("‹", "open_item:#{previous_id}") : context.inline_btn("·", "noop"),
          back,
          next_id ? context.inline_btn("›", "open_item:#{next_id}") : context.inline_btn("·", "noop")
        ]
      end

      # Only http(s) links can go into a URL button, anything else is shown as text
      def web_url
        return @web_url if defined?(@web_url)

        uri = URI.parse(item.url.to_s.strip)
        @web_url = uri.is_a?(URI::HTTP) && uri.host.present? ? uri : nil
      rescue URI::InvalidURIError
        @web_url = nil
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
        item.reserved_by == user.telegram_id
      end

      def owner?
        wishlist.user_id == user.id
      end
    end
  end
end
