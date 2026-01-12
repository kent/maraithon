defmodule Maraithon.Effects do
  @moduledoc """
  Effect outbox for managing side effects.
  """

  alias Maraithon.Repo
  alias Maraithon.Effects.Effect

  @doc """
  Request an effect to be executed.
  """
  def request(agent_id, effect_type, tool_name, params, opts \\ %{}) do
    effect_id = opts[:effect_id] || Ecto.UUID.generate()
    idempotency_key = opts[:idempotency_key] || Ecto.UUID.generate()

    params =
      if tool_name do
        Map.put(params, "tool", tool_name)
      else
        params
      end

    attrs = %{
      id: effect_id,
      agent_id: agent_id,
      effect_type: to_string(effect_type),
      params: params,
      idempotency_key: idempotency_key,
      status: "pending",
      attempts: 0,
      max_attempts: 3
    }

    case %Effect{} |> Effect.changeset(attrs) |> Repo.insert() do
      {:ok, effect} -> {:ok, effect.id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if an effect has already been executed (for idempotency).
  """
  def check_idempotency(idempotency_key) do
    case Repo.get_by(Effect, idempotency_key: idempotency_key) do
      %Effect{status: "completed", result: result} -> {:cached, result}
      %Effect{status: "failed", error: error} -> {:cached_error, error}
      _ -> :not_found
    end
  end
end
