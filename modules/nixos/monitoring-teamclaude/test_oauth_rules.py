"""Feed the actual edi provisioning queries to Prometheus, no live datasource."""
import json
from pathlib import Path
import sys

raw = json.loads(Path(sys.argv[1]).read_text())
alarm = {r['uid']: r for r in raw}
relogin = alarm['teamclaude-oauth-relogin']
blind = alarm['teamclaude-oauth-telemetry']
for r, delay in [(relogin, '15m'), (blind, '30m')]:
    assert r['for'] == delay and r['labels'] == {'severity': 'warning'}
    assert r['noDataState'] == 'OK' and r['execErrState'] == 'Error'
    assert 'docs/teamclaude-oauth-recovery.md' in r['annotations']['summary']
    assert r['data'][0]['model']['instant']
    threshold = r['data'][1]['model']['conditions'][0]['evaluator']
    assert threshold == {'params': [0], 'type': 'gt'}

assert '.Labels.account' not in relogin['annotations']['summary']


def series(metric, value, account=None, instance='som'):
    labels = f'instance="{instance}",job="integrations/unix"'
    if account:
        labels += f',account="{account}"'
    return {'series': f'teamclaude_{metric}{{{labels}}}', 'values': f'_x59 {value}'}


def rejected(account, value, instance='som'):
    return series('account_oauth_relogin_required', value, account, instance)


def expiry(account, value, instance='som'):
    return series('account_oauth_refresh_expiry_timestamp_seconds', value, account, instance)


def heartbeat(value, instance='som'):
    return series('oauth_status_collected_timestamp_seconds', value, instance=instance)


def sample(account, value):
    return {'labels': f'{{account="{account}",instance="som"}}', 'value': value}


def test(inputs, accounts=(), monitoring_blind=False):
    pairs = [(relogin, list(accounts)), (blind, [{'labels': '{instance="som"}', 'value': 1}] if monitoring_blind else [])]
    return {
        'interval': '1m', 'input_series': inputs,
        'promql_expr_test': [{'expr': rule['data'][0]['model']['expr'], 'eval_time': '1h', 'exp_samples': result}
                             for rule, result in pairs],
    }


signals = [
    expiry('on-boundary', 176400), expiry('outside-window', 176401),
    expiry('overdue', 3500), expiry('invalid-zero', 0), rejected('unknown-expiry', 0),
    rejected('rejected-without-date', 1), rejected('both-signals', 1), expiry('both-signals', 3500),
    rejected('other-gateway', 1, 'other'),
]
tests = [
    test([heartbeat(3600), *signals], [sample('on-boundary', 176400), sample('overdue', 3500),
                                       sample('rejected-without-date', 1), sample('both-signals', 1)]),
    test([heartbeat(3480), expiry('recovered', 1000000), rejected('recovered', 0)]),
    test([heartbeat(3720), rejected('rejected-without-date', 1)], [sample('rejected-without-date', 1)]),
    # Same old values being re-scraped by Alloy are still stale.
    test([heartbeat(2400), *signals], monitoring_blind=True),
    test([heartbeat(3721), *signals], monitoring_blind=True),
    test([heartbeat(3600, 'other'), *signals], monitoring_blind=True),
    test(signals, monitoring_blind=True),
]
Path(sys.argv[2]).write_text(json.dumps({'evaluation_interval': '1m', 'tests': tests}))
print(f'Assembled {len(tests)} PromQL scenarios from actual edi rules')
