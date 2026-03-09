# Gang Of Four Patterns In Maraithon

This repository uses GoF patterns in places where they improve extensibility and operations.

## Command + Factory Method

- Location: `Maraithon.Runtime.Effects.*`
- Purpose: decouple `EffectRunner` from effect-type branching logic.
- Implementation:
  - `Maraithon.Runtime.Effects.Command` defines the execution contract.
  - `LLMCallCommand` and `ToolCallCommand` encapsulate executable behaviors.
  - `CommandFactory.fetch/1` resolves effect type to command module.
- Result: adding a new effect type no longer requires editing execution control flow.

## Strategy

- Location: `Maraithon.Behaviors.*` and `Maraithon.Connectors.*`
- Purpose: swap runtime behavior by module, not conditionals.
- Implementation:
  - `Maraithon.Behaviors.Behavior` for agent behavior strategies.
  - `Maraithon.Connectors.Connector` for external webhook parsing strategies.
- Result: behavior and connector variants remain isolated and testable.

## State

- Location: `Maraithon.Runtime.Agent`
- Purpose: model long-lived agent lifecycle explicitly.
- Implementation:
  - `gen_statem` states (`:idle`, `:working`, etc.) and transitions.
- Result: predictable transitions and safer recovery for long-running OTP processes.

## Observer

- Location: `Phoenix.PubSub` usage across runtime and connectors.
- Purpose: broadcast domain events without tight coupling.
- Implementation:
  - connectors publish events, agents subscribe by topic.
- Result: scalable fan-out and loose coupling between integrations and agents.
