# Hassock

Home Assistant WebSocket client for Elixir.

Hassock connects to a Home Assistant instance over its WebSocket API,
authenticates, and lets your application subscribe to entity state changes,
call services, and (optionally) keep an in-memory ETS cache of the world.

It follows the controlling-process pattern from `:gen_tcp` /
`Circuits.UART`: the process that calls `start_link/1` becomes the recipient
of async messages, and ownership can be handed off explicitly with
`controlling_process/2`.

Requires Home Assistant ≥ 2022.4 if you use `Hassock.Boundary.StateCache`
(`subscribe_entities` was added in that release).

## Installation

```elixir
def deps do
  [
    {:hassock, "~> 0.1.0"}
  ]
end
```

## Usage

### Bare connection — for targeted subscriptions

Subscribe only to the entities (or events) you care about; do everything else
manually.

```elixir
config = %Hassock.Core.Config{
  url: "http://homeassistant.local:8123",
  token: System.fetch_env!("HASSOCK_TOKEN")
}

{:ok, conn} = Hassock.connect(config: config)

receive do
  {:hassock, ^conn, :connected} -> :ok
end

{:ok, _sub_id} = Hassock.subscribe_entities(conn, ["light.kitchen"])

# In your handle_info/2 (or a receive loop):
#
# {:hassock, ^conn, {:event, {:entities, %{added: a, changed: c, removed: r}}}} -> ...
# {:hassock, ^conn, {:disconnected, reason}}                                    -> ...
```

To call a service:

```elixir
Hassock.call_service(conn, %Hassock.Core.ServiceCall{
  domain: "light",
  service: "toggle",
  target: %{entity_id: "light.kitchen"}
})
```

### With a state cache — for "show me everything" use cases

`Hassock.Boundary.StateCache` subscribes to every entity, holds the world in
ETS, and emits high-level change messages. Reads are direct ETS lookups —
no GenServer roundtrip.

```elixir
{:ok, conn} = Hassock.connect(config: config)
{:ok, cache} = Hassock.Boundary.StateCache.start_link(connection: conn)

receive do
  {:hassock_cache, ^cache, :ready} -> :ok
end

Hassock.cached_state(cache, "light.kitchen")
Hassock.cached_domain(cache, "light")
```

Cache messages:

  * `{:hassock_cache, cache, :ready}` — once, after the initial snapshot loads
  * `{:hassock_cache, cache, {:changes, %{added: _, changed: _, removed: _}}}` — per delta
  * `{:hassock_cache, cache, :disconnected}` — on socket loss (ETS retained)

> **Note on ownership:** `StateCache.start_link/1` *transfers ownership* of
> the connection to the cache. After it returns, the cache receives all
> `{:hassock, conn, …}` messages — your code talks to the cache, not the
> connection, for async events. (Synchronous calls like `call_service/2` and
> `get_states/1` still work directly on `conn`.)

### Hand off message reception

```elixir
:ok = Hassock.controlling_process(conn, other_pid)
:ok = Hassock.Boundary.StateCache.controlling_process(cache, other_pid)
```

Only the current controller may transfer ownership.

### Convenience supervisor

If you want a single child spec for your application's supervision tree:

```elixir
{Hassock.Lifecycle.Supervisor,
 config: config,
 cache: true,
 controller: my_handler_pid}
```

This wires Connection + StateCache under a `rest_for_one` supervisor and
delivers cache events to `controller` (default: caller).

## Architecture

Layered per *Designing Elixir Systems with OTP* (Gray & Tate):

  * `lib/hassock/core/` — pure data and parsing. No processes.
    * `Hassock.Core.Config`, `EntityState`, `ServiceCall`, `Messages`
  * `lib/hassock/boundary/` — processes that own state and side effects.
    * `Hassock.Boundary.Connection` — the WebSocket itself
    * `Hassock.Boundary.StateCache` — optional ETS-backed full mirror
  * `lib/hassock/lifecycle/` — application + optional convenience supervisor.

## Development

```bash
mix deps.get
mix test
```

Integration tests are tagged `:integration` and skipped by default. To run
them against a live Home Assistant:

```bash
HASSOCK_URL=http://homeassistant.local:8123 \
HASSOCK_TOKEN=... \
HASSOCK_LIGHT_ENTITY=light.your_light \
mix test --include integration
```

`HASSOCK_LIGHT_ENTITY` is optional — without it, light-toggle assertions
auto-discover the first available `light.*` entity or skip.
