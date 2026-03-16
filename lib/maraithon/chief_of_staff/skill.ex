defmodule Maraithon.ChiefOfStaff.Skill do
  @moduledoc """
  Internal capability contract for the AI Chief of Staff behavior.

  Skills intentionally mirror the runtime behavior callbacks so existing
  structured workflow modules can be adapted with minimal rewrite in the first
  implementation slice.
  """

  alias Maraithon.Behaviors.Behavior

  @callback id() :: String.t()
  @callback default_config() :: map()
  @callback requirements() :: [map()]
  @callback subscriptions(config :: map(), user_id :: String.t()) :: [String.t()]
  @callback init(config :: map()) :: Behavior.state()

  @callback handle_wakeup(Behavior.state(), Behavior.context()) ::
              {:effect, Behavior.effect(), Behavior.state()}
              | {:emit, {atom(), map()}, Behavior.state()}
              | {:continue, Behavior.state()}
              | {:idle, Behavior.state()}

  @callback handle_effect_result(
              {:llm_call | :tool_call, result :: any()},
              Behavior.state(),
              Behavior.context()
            ) ::
              {:emit, {atom(), map()}, Behavior.state()}
              | {:effect, Behavior.effect(), Behavior.state()}
              | {:idle, Behavior.state()}

  @callback next_wakeup(Behavior.state()) :: Behavior.wakeup_schedule()
end
