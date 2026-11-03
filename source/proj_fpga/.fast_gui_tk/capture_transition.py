"""起摆参数与稳态参数的主机切换，需连续接管后才允许切入稳态。"""
from j280_protocol import PARAM, validate_value


CAPTURE_KEYS = frozenset(('AKP','AKI','AKD','PKP','PKD','PKDNEAR','POS_NEAR','PKI',
                         'PILIM','PIDEAD','KDBLEND','TRIM','DLP','ALP','RATEMODE',
                         'VELMODE','ADCAVG','RLP','DZ','DZW','DZLP','SLEW','ILIM'))


def read_capture(data):
    if not data.get('staged_start', False):
        return {}
    values = data.get('capture_params')
    if not isinstance(values, dict) or not values:
        raise ValueError('分阶段起摆配置缺少capture_params')
    if set(values)-set(PARAM) or 'MODE' in values:
        raise ValueError('起摆配置含未知参数或MODE')
    if not CAPTURE_KEYS.issubset(values):
        raise ValueError('起摆控制参数不完整')
    return {'HOLDPOS':0, **{key:validate_value(key,value) for key,value in values.items()}}


def prepare_capture(steady, capture):
    # 保留当前ZERO、目标、起摆力度与保护门限，只替换记录中的捕获环路参数。
    return {**steady, **{key:value for key,value in capture.items() if key in CAPTURE_KEYS},
            'HOLDPOS':0}


class CaptureTransition:
    def __init__(self, steady, now):
        self.steady = dict(steady)
        self.started = now
        self.last_rx = None
        self.stable_since = None

    def update(self, row, now):
        if now-self.started>=18:
            return 'timeout'
        if not row or now-row.get('received',-1)>.3:
            self.stable_since=None
            if self.last_rx is not None and now-self.last_rx>.7:
                return 'stale'
            return None
        stamp=row['received']
        if stamp==self.last_rx:
            return None
        if self.last_rx is not None and stamp-self.last_rx>.3:
            self.stable_since=None
        self.last_rx=stamp
        if row.get('src_local')==1:
            return 'local'
        if row['mode']!=2:
            self.stable_since=None
            return 'cancel' if now-self.started>1 else None
        balanced=bool(row['bal_status']&4 and not row['bal_status']&10)
        if not balanced:
            self.stable_since=None
            return None
        if self.stable_since is None:
            self.stable_since=stamp
        return 'ready' if stamp-self.stable_since>=2 else None
