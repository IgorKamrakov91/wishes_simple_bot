# One row per model call that is not a gift idea request, so every kind of
# AI use shares one app-wide daily cap. Only the kind and the person are kept.
class CreateAiCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_calls do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.datetime :created_at, null: false
    end
    add_index :ai_calls, :created_at
    add_index :ai_calls, [ :user_id, :kind, :created_at ]
  end
end
