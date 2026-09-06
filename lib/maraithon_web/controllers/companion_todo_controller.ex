defmodule MaraithonWeb.CompanionTodoController do
  @moduledoc """
  Least-privilege Todo mutations for a paired macOS companion.

  Reads are served by `MobileTodoController` so the Mac and iPhone share one
  stable JSON contract. This controller exposes manual creation, completion,
  dismissal, and reopening. The authenticated device determines the user;
  request data can never select an account.
  """

  use MaraithonWeb, :controller

  alias Maraithon.Todos
  alias MaraithonWeb.MobileJSON

  def create(conn, %{"title" => title, "request_id" => request_id} = params)
      when is_binary(title) do
    with {:ok, request_id} <- Ecto.UUID.cast(request_id),
         title when title != "" <- String.trim(title) do
      user_id = conn.assigns.current_user_id
      device_id = conn.assigns.current_device.id

      attrs =
        params
        |> Map.take(~w(notes next_action due_at priority))
        |> Map.merge(%{
          "title" => title,
          "summary" => title,
          "source" => "manual",
          "dedupe_key" => "companion:manual:#{device_id}:#{request_id}"
        })
        |> Map.put_new("next_action", title)

      case Todos.upsert_many(user_id, [attrs], actor_opts(user_id)) do
        {:ok, [todo]} ->
          conn |> put_status(:created) |> json(%{todo: MobileJSON.todo(todo)})

        {:error, reason} ->
          respond(conn, {:error, reason}, "create")
      end
    else
      _invalid -> respond(conn, {:error, :invalid_todo_attrs}, "create")
    end
  end

  def create(conn, _params), do: respond(conn, {:error, :invalid_todo_attrs}, "create")

  def done(conn, %{"id" => todo_id}) do
    user_id = conn.assigns.current_user_id

    result =
      case Todos.get_for_user(user_id, todo_id) do
        %{status: "done"} = todo -> {:ok, todo}
        nil -> {:error, :not_found}
        _todo -> Todos.mark_done(user_id, todo_id, actor_opts(user_id))
      end

    respond(conn, result, "done")
  end

  def reopen(conn, %{"id" => todo_id}) do
    user_id = conn.assigns.current_user_id

    result =
      case Todos.get_for_user(user_id, todo_id) do
        %{status: "open"} = todo ->
          {:ok, todo}

        nil ->
          {:error, :not_found}

        _todo ->
          Todos.update_for_user(user_id, todo_id, %{"status" => "open"}, actor_opts(user_id))
      end

    respond(conn, result, "reopen")
  end

  def dismiss(conn, %{"id" => todo_id}) do
    user_id = conn.assigns.current_user_id

    result =
      case Todos.get_for_user(user_id, todo_id) do
        %{status: "dismissed"} = todo -> {:ok, todo}
        nil -> {:error, :not_found}
        _todo -> Todos.dismiss(user_id, todo_id, actor_opts(user_id))
      end

    respond(conn, result, "dismiss")
  end

  defp respond(conn, {:ok, todo}, action) do
    json(conn, %{todo: MobileJSON.todo(todo), action: action})
  end

  defp respond(conn, {:error, :not_found}, _action) do
    conn
    |> put_status(:not_found)
    |> json(MobileJSON.error(:not_found))
  end

  defp respond(conn, {:error, reason}, _action) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(MobileJSON.error(reason))
  end

  defp actor_opts(user_id) do
    [actor_type: "user", actor_id: user_id, actor_label: "User on Mac", source: "companion"]
  end
end
