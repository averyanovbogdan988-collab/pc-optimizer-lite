from __future__ import annotations

import json

from core.obs_optimizer import optimize_obs_action


if __name__ == "__main__":
    report = optimize_obs_action()
    print(json.dumps(report, ensure_ascii=False, indent=2))
