# CI 作业日志生成器：每 2s 一行 INFO，每 5 行一个 ERROR（供 LogQL 速率与告警）
import time, random

with open("/var/log/ci/app.log", "a") as f:
    f.write("INFO ci start build pipeline\n"); f.flush()
    n = 0
    while True:
        n += 1
        if n % 5 == 0:
            line = "ERROR ci build step failed (exit 1)"
        else:
            line = "INFO ci build ok step=%d dur=%.1fs" % (n, random.uniform(0.5, 9.9))
        f.write(line + "\n")
        f.flush()
        time.sleep(2)
