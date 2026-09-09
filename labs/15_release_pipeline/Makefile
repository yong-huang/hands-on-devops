# 实验 15 · 手工发布流水线：make release VERSION=1.2.3
VERSION ?= dev
REG     ?= localhost:5500

.PHONY: release verify-remote clean

release:
	./release_pipeline.sh release VERSION=$(VERSION) REG=$(REG)

verify-remote:
	COSIGN_PASSWORD="" cosign verify --key tmp/cosign.pub $(REG)/demo/webapp:$(VERSION) >/dev/null && echo "[ok] 远端验签通过"

clean:
	./release_pipeline.sh clean
