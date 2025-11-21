class CreateItems < ActiveRecord::Migration[8.1]
  def change
    create_table :items do |t|
      t.references :wishlist, null: false, foreign_key: true
      t.string :title, null: false
      t.text :description
      t.string :url
      t.decimal :price, precision: 10, scale: 2
      t.bigint :reserved_by # telegram_id

      t.timestamps
    end

    add_index :items, :reserved_by
  end
end
