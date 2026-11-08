# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_08_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "birthday_reminder_deliveries", force: :cascade do |t|
    t.bigint "recipient_id", null: false
    t.bigint "owner_id", null: false
    t.integer "birthday_year", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "claimed_at"
    t.datetime "retry_at"
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_birthday_reminder_deliveries_on_owner_id"
    t.index ["recipient_id", "owner_id", "birthday_year"], name: "index_birthday_reminders_on_recipient_owner_year", unique: true
    t.index ["recipient_id"], name: "index_birthday_reminder_deliveries_on_recipient_id"
  end

  create_table "bot_update_receipts", primary_key: "update_id", force: :cascade do |t|
    t.bigint "telegram_user_id", null: false
    t.string "result_kind", default: "processed", null: false
    t.bigint "result_id"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_bot_update_receipts_on_created_at"
  end

  create_table "items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.decimal "price", precision: 10, scale: 2
    t.bigint "reserved_by"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.bigint "wishlist_id", null: false
    t.bigint "reservation_version", default: 0, null: false
    t.datetime "purchased_at"
    t.datetime "thanked_at"
    t.index ["reserved_by"], name: "index_items_on_reserved_by"
    t.index ["wishlist_id"], name: "index_items_on_wishlist_id"
  end

  create_table "list_viewers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "wishlist_id", null: false
    t.index ["user_id"], name: "index_list_viewers_on_user_id"
    t.index ["wishlist_id", "user_id"], name: "index_list_viewers_on_wishlist_id_and_user_id", unique: true
    t.index ["wishlist_id"], name: "index_list_viewers_on_wishlist_id"
  end

  create_table "users", force: :cascade do |t|
    t.json "bot_payload"
    t.string "bot_state"
    t.datetime "created_at", null: false
    t.string "first_name"
    t.string "last_name"
    t.datetime "last_seen_at"
    t.bigint "telegram_id", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.boolean "notify_own_reservations", default: true, null: false
    t.boolean "notify_friend_reservations", default: false, null: false
    t.integer "reservation_reminder_days", default: 0, null: false
    t.datetime "reservation_reminder_next_at"
    t.datetime "reservation_reminder_last_attempt_at"
    t.datetime "reservation_reminder_last_sent_at"
    t.boolean "notify_birthdays", default: true, null: false
    t.integer "birthdate_day"
    t.integer "birthdate_month"
    t.datetime "birthdate_checked_at"
    t.datetime "birthdate_synced_at"
    t.bigint "last_list_creation_message_id"
    t.index ["reservation_reminder_next_at"], name: "index_users_on_reservation_reminder_next_at"
    t.index ["telegram_id"], name: "index_users_on_telegram_id", unique: true
    t.check_constraint "reservation_reminder_days = ANY (ARRAY[0, 7, 14, 30])", name: "users_reservation_reminder_days"
  end

  create_table "wishlists", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "share_token", null: false
    t.index ["share_token"], name: "index_wishlists_on_share_token", unique: true
    t.index ["user_id"], name: "index_wishlists_on_user_id"
  end

  add_foreign_key "birthday_reminder_deliveries", "users", column: "owner_id", on_delete: :cascade
  add_foreign_key "birthday_reminder_deliveries", "users", column: "recipient_id", on_delete: :cascade
  add_foreign_key "items", "wishlists"
  add_foreign_key "list_viewers", "users"
  add_foreign_key "list_viewers", "wishlists"
  add_foreign_key "wishlists", "users"
end
