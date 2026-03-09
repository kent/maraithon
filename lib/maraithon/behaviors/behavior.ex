defmodule Maraithon.Behaviors.Behavior do
  @moduledoc """
  Behaviour specification for agent behaviors.
  """

  @type state :: any()
  @type context :: %{
          agent_id: String.t(),
          user_id: String.t() | nil,
          timestamp: DateTime.t(),
          budget: map(),
          recent_events: [map()],
          last_message: String.t() | nil,
          event: map() | nil
        }

  @type effect ::
          {:llm_call, params :: map()}
          | {:tool_call, tool :: String.t(), args :: map()}

  @type wakeup_schedule ::
          {:relative, milliseconds :: pos_integer()}
          | {:absolute, DateTime.t()}
          | :none

  @doc """
  Initialize behavior state from config.
  """
  @callback init(config :: map()) :: state()

  @doc """
  Handle a wakeup event.

  Returns:
    - `{:effect, effect, state}` - Request an effect (LLM call, tool call)
    - `{:emit, {event_type, payload}, state}` - Emit an event and return to idle
    - `{:continue, state}` - Continue working (re-enter handle_wakeup)
    - `{:idle, state}` - Return to idle state
  """
  @callback handle_wakeup(state(), context()) ::
              {:effect, effect(), state()}
              | {:emit, {atom(), map()}, state()}
              | {:continue, state()}
              | {:idle, state()}

  @doc """
  Handle the result of an effect.

  Returns same as handle_wakeup.
  """
  @callback handle_effect_result({:llm_call | :tool_call, result :: any()}, state(), context()) ::
              {:emit, {atom(), map()}, state()}
              | {:effect, effect(), state()}
              | {:idle, state()}

  @doc """
  Determine when to schedule the next wakeup.
  """
  @callback next_wakeup(state()) :: wakeup_schedule()
end
