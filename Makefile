# hands-on-devops 统一入口
# 靶场环境由实验 05 的 Terraform 声明（nginx 应用 + registry + MinIO + Gitea），
# 这里只是薄封装：细节与 endpoints 输出见 labs/05_lab_foundation/。
SHELL  := /bin/bash
LAB05  := labs/05_lab_foundation

.PHONY: help lab-up lab-down lab-status demo

help:
	@echo "make lab-up      一键拉起靶场（TF apply，幂等）"
	@echo "make lab-status  查看靶场容器与 endpoints"
	@echo "make lab-down    销毁靶场（TF destroy，全清）"
	@echo "make demo        实验 30 完整故事线（前置 01-29）"

lab-up:
	cd $(LAB05) && ./lab_foundation.sh apply

lab-status:
	cd $(LAB05) && ./lab_foundation.sh observe

lab-down:
	cd $(LAB05) && ./lab_foundation.sh clean

demo:
	cd labs/30_all_in_one && ./all_in_one.sh demo
