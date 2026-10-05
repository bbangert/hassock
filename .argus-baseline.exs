# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "mailbox",
    file: "lib/hassock/connection.ex",
    title: "Entry dropped while its process stays monitored",
    at_label: "monitored here; the entry is dropped elsewhere",
    detail:
      "Hassock.Connection.handle_sync/3 runs again and again: each run monitors a process and records it in Hassock.Connection. Another of Hassock.Connection's callbacks drops that record while the process may still be alive (a delete, an unsubscribe, a reset) and does not demonitor it. The monitor outlives the entry it stood for: when the same process registers again it is monitored again, and the old monitors pile up until it exits.",
    reason:
      "False positive: the only monitor handle_sync/3 takes is on the new controller in {:set_controlling, ...}, kept in `controlling_monitor`, and the previous one is `Process.demonitor(ref, [:flush])`ed right before it is replaced. That field is cleared only by the matching :DOWN handler (controller already dead). The drops argus points at (handle_disconnect/2 resetting `pending: %{}`, route/2) clear `pending`, which holds caller-owned `:reply_demonitor` aliases from sync_request/3, not monitors this process took; the caller demonitors its own alias on reply or timeout. The related real leak (handle_connect/2 re-monitoring the controller on every reconnect) is fixed."
  }
]
