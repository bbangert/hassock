# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "mailbox",
    file: "lib/hassock/registry_cache.ex",
    title: "Async task never awaited",
    at_label: "task started here",
    detail:
      "Hassock.RegistryCache.do_start_task/2 starts a task with Task.async (or async_nolink) but nothing awaits or yields it. Task.async links to the caller and always sends a result message: a crashing task takes the caller down, and completed results accumulate unread in the mailbox.",
    reason:
      "False positive: the task's result is consumed in handle_info({ref, result}, %State{task: {ref, job}}), the pattern the Task docs give for tasks started from a GenServer, which also demonitors with :flush. The cache traps exits and handles the task's :DOWN (crash) the same way, so a crashing task is reported as a failed load/re-list and retried rather than taking the cache down. At most one task runs at a time (state.task)."
  },
  %{
    analysis: "mailbox",
    file: "test/support/test_helpers.ex",
    title: "Task.async in library code links to an unknown caller",
    at_label: "linked task started in library code",
    detail:
      "Hassock.TestHelpers.subscribe/3 is a plain function, not a process callback, so the task it starts with Task.async is linked to whichever process called it. A caller that traps exits then receives the task's exit as an {:EXIT, pid, :normal} message that collecting the task (Task.await, Task.yield) never consumes, and a crashing task takes the caller down with it.",
    reason:
      "Test-only helper (test/support, compiled only in MIX_ENV=test). It awaits its task at once with Task.await, and it is called only from ExUnit test processes, none of which trap exits while using it, so no {:EXIT, pid, :normal} message is left behind and a crash failing the test is the intended outcome."
  }
]
