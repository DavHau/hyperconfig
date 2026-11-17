# The recurring-task SLO checks as PromQL, shared by the Grafana rules
# (../monitoring-alerts.nix) and the VM test (./test.nix), so the test
# runs the expressions that alert. Each returns only breaching series
# (value > 0), labelled instance, task and `why`.
{ lib }:
let
  by = "max by (instance, task)";
  slo = kind: "${by} (recurring_task_slo_seconds{kind=\"${kind}\"})";
  why = w: e: ''label_replace(${e}, "why", "${w}", "", "")'';
in
{
  # Seconds past the limit, or the limit itself when nothing is on record.
  stale = lib.concatStringsSep " or " [
    (why "late: no successful run within its SLO" "((time() - ${by} (recurring_task_last_success_seconds)) - on (instance, task) ${slo "run"}) > 0")
    (why "no successful run on record" "${slo "run"} unless on (instance, task) recurring_task_last_success_seconds")
    (why "result older than its SLO" "(${by} (recurring_task_result_age_seconds) - on (instance, task) ${slo "result"}) > 0")
    (why "result not measured (probe failing)" "${slo "result"} unless on (instance, task) recurring_task_result_age_seconds")
  ];

  # The exporter itself: its timestamp stops moving when its timer dies
  # (Alloy keeps re-reading the last file) or the file is gone. Seconds
  # of silence, per host; only for a host that has reported within 30
  # days, so a host in the registry that is not deployed yet stays quiet.
  exporterSilent =
    hosts:
    lib.concatMapStringsSep " or " (
      host:
      ''(time() - max by (instance) (last_over_time(recurring_tasks_exporter_last_run_seconds{instance="${host}"}[30d]))) > 3600''
    ) hosts;
}
