class CreateListViewers < ActiveRecord::Migration[8.1]
  def change
    create_table :list_viewers do |t|
      t.references :wishlist, null: false, foreign_key: true
      t.bigint :telegram_id, null: false
      t.datetime :last_opened_at, null: false

      t.timestamps
    end

    add_index :list_viewers, [:wishlist_id, :telegram_id], unique: true
  end
end
