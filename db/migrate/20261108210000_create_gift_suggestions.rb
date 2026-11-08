class CreateGiftSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :gift_suggestions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :wishlist, null: false, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: "pending"
      t.jsonb :ideas, null: false, default: []
      t.string :error_code
      t.string :locale, null: false, default: "ru"
      t.datetime :started_at
      t.timestamps
    end
    add_index :gift_suggestions, [ :user_id, :created_at ]
    add_index :gift_suggestions, :created_at
  end
end
