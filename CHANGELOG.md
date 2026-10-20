# Changelog

## 0.3.0

### Added

- `Hassock.command/4` sends any WebSocket command and waits for its result
  (`:timeout` option, default 10 s).
- Registries: `Hassock.Registries.list_floors/2`, `list_areas/2`,
  `list_devices/2`, `list_entities/2` and `list_labels/2`, decoding into the
  new `Hassock.Floor`, `Hassock.Area`, `Hassock.Device`,
  `Hassock.EntityEntry` and `Hassock.Label` structs.
- `Hassock.RegistryCache`: the five registries in ETS, re-listed (debounced)
  on their update events and after every reconnect. `Hassock.Supervisor`
  starts one with `registries: true` (name it with `:registry_cache_name`).
- The `*_registry_updated` events arrive as
  `{:event, {:registry_updated, kind, action, id}}`
  (`Hassock.Protocol.registry_event_types/0` lists them).
- `return_response: true` on `%Hassock.ServiceCall{}`; `call_service/3`
  takes a `:timeout` option.
- `Hassock.status/1` (status, failed attempts, next retry time), and
  `Hassock.watch/1` / `unwatch/1` (lifecycle messages for processes other
  than the controller).
- `:to` and `:timeout` options on `subscribe_entities/3` and
  `subscribe_events/3`; `:to` sends a subscription's events to a given pid
  instead of the controller.
- `{:subscription_lost, id, error}` when HA refuses to restore a
  subscription after a reconnect.
- `%Hassock.Config{}` fields: `ssl_options`, `ping_interval`,
  `ping_timeout`, `backoff_initial`, `backoff_max`, `connect_timeout`;
  invalid values make `start_link/1` fail with `{:invalid_config, key}`.
- `Hassock.Cache` passes `{:auth_failed, reason}` on to its controller.

### Changed

These change behaviour for 0.2 code:

- `Hassock.Connection` is a GenServer that owns a WebSocket process per
  connection attempt. `start_link/1` returns before the connection is up
  (it used to block, forever if Home Assistant was down); wait for
  `{:hassock, conn, :connected}` before sending commands.
- Reconnects back off exponentially with jitter (1 s doubling to 30 s)
  instead of retrying in a tight loop, and `{:disconnected, reason}` is sent
  once per outage instead of once per attempt. The backoff resets once a
  connection has stayed up for `backoff_max`.
- An attempt that hasn't authenticated within 15 s is abandoned, and a
  subscription restore HA doesn't answer within that time re-makes the
  connection.
- Subscriptions are restored after every reconnect and keep their ids.
  Code that resubscribes on `:connected` now gets duplicate subscriptions;
  remove it.
- A keepalive ping every 30 s; a missing pong re-makes the connection.
- After `auth_invalid` the connection stops retrying (Home Assistant bans
  IPs after repeated failed logins). A controller set afterwards still
  gets `{:auth_failed, reason}`.
- When the controller exits, any process may take control with
  `controlling_process/2` (before, nobody could).
- A subscribe whose caller timed out is cancelled at HA when its result
  arrives, and events for cancelled subscriptions are dropped instead of
  reaching the controller.
- `get_states/1` and `get_services/1` return
  `{:error, {:unexpected_result, result}}` for a malformed result instead of
  crashing the connection.
- `inspect/1` of `%Hassock.Config{}` leaves out the token and `ssl_options`.
- `wss://` connections verify the server certificate against the system CA
  store. Without a store, a warning is logged and the certificate isn't
  verified; set `ssl_options`. URL schemes are matched in any letter case.
- Events without an `event_type` are decoded as `subscribe_entities` updates
  only when they carry just the `a`/`c`/`r` keys; others (for example a
  `render_template` subscription made with `command/4`) arrive whole as
  `{:other, nil, raw_event}` (parse: `{:event, id, nil, event}`).
- `Hassock.Protocol.parse/1` returns pongs as `{:pong, id}` (was `:pong`), so
  a `"ping"` sent with `command/4` gets its answer.
- `Hassock.Protocol.parse/1` returns every result as
  `{:result, id, success, result}`; the `{:states, ...}` and
  `{:services, ...}` variants are gone (`Hassock.Protocol.decode_states/1`
  and `Hassock.Protocol.decode_services/1` decode them). Invalid JSON returns
  `{:invalid, error}` instead of raising.
- `Hassock.Cache` diffs the snapshot that follows a reconnect against its
  table: entities removed during the outage are deleted, and a `:changes`
  message with the difference comes before `:ready`.
- `Hassock.Cache` reads go to ETS without calling the cache process.
- Message ids keep increasing across reconnects instead of restarting at 1.
- Calls on a registered name with no process return
  `{:error, {:connection_down, :noproc}}` instead of raising.
- `Hassock.Supervisor` with `cache: true` starts the connection without a
  controller, so no message reaches the supervisor before the cache claims
  it.

### Fixed

- Results were decoded by their shape, so an entity registry list (a list
  of maps with `"entity_id"`) or an empty list was dropped and the caller
  timed out. Results are now decoded by the command that was sent.
- A malformed frame no longer crashes the connection.
- `Hassock.Cache` kept rows for entities deleted while disconnected.

## 0.2.0

- websockex 0.5.
- CI gates (Credo, Dialyzer, Sobelow, hex audit, Argus) and the fixes they
  raised, including the controller monitor being re-added on every
  reconnect.

## 0.1.x

- Initial releases: `Hassock.Connection`, `Hassock.Cache`,
  `Hassock.Supervisor`. 0.1.3 fixed `Hassock.Cache` dropping events when
  started through the supervisor.
