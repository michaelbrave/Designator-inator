defmodule ForgeClaw.Memory.Repo.Migrations.CreateConversationMessages do
  use Ecto.Migration

  def change do
    create table(:conversation_messages) do
      add :pod_name,     :string,  null: false
      add :session_id,   :string,  null: false
      add :role,         :string,  null: false
      add :content,      :text
      add :tool_calls,   :text
      add :tool_call_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:conversation_messages, [:pod_name, :session_id])
    create index(:conversation_messages, [:session_id])
  end
end
