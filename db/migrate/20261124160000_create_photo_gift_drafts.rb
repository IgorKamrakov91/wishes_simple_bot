class CreatePhotoGiftDrafts < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :photo_ai_consented_at, :datetime
    add_column :items, :photo_file_id, :string

    create_table :photo_gift_drafts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :wishlist, foreign_key: { on_delete: :nullify }
      t.references :item, foreign_key: { on_delete: :nullify }
      t.bigint :chat_id, null: false
      t.bigint :message_id, null: false
      t.string :media_group_id
      t.string :file_id, null: false
      t.string :file_unique_id
      t.string :photo_file_id
      t.string :media_kind, null: false, default: "photo"
      t.string :media_status, null: false, default: "ready"
      t.text :caption
      t.string :locale, null: false
      t.string :status, null: false, default: "awaiting_consent"
      t.jsonb :result, null: false, default: {}
      t.string :error_code
      t.integer :version, null: false, default: 0
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :photo_gift_drafts, [ :chat_id, :message_id ], unique: true
    add_index :photo_gift_drafts, [ :user_id, :media_group_id ], unique: true, where: "media_group_id IS NOT NULL"
    add_index :photo_gift_drafts, :expires_at
    add_check_constraint :photo_gift_drafts, "version >= 0", name: "photo_gift_drafts_version"
  end
end
