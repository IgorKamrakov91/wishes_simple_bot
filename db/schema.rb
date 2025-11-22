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

ActiveRecord::Schema[8.1].define(version: 2025_11_22_121846) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.decimal "price", precision: 10, scale: 2
    t.bigint "reserved_by"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.bigint "wishlist_id", null: false
    t.index ["reserved_by"], name: "index_items_on_reserved_by"
    t.index ["wishlist_id"], name: "index_items_on_wishlist_id"
  end

  create_table "list_viewers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_opened_at", null: false
    t.bigint "telegram_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "wishlist_id", null: false
    t.index ["wishlist_id", "telegram_id"], name: "index_list_viewers_on_wishlist_id_and_telegram_id", unique: true
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
    t.index ["telegram_id"], name: "index_users_on_telegram_id", unique: true
  end

  create_table "wishlists", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_wishlists_on_user_id"
  end

  add_foreign_key "items", "wishlists"
  add_foreign_key "list_viewers", "wishlists"
  add_foreign_key "wishlists", "users"
end
