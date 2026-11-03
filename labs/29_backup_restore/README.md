# 29 · 备份与灾难恢复演练：备份 → 灾难 → 恢复 → 冒烟（RTO 实测）

> 什么必须备份（数据卷/state）、什么可重建（容器/网络/镜像）——备份清单文档化；灾难演练真实**销毁数据卷**；恢复后端到端冒烟；RTO 分段计时。

## Background

备份的价值只有在"真删了还能回来"时才成立。本实验的灾难是**真灾难**：`destroy` 相删除 Gitea/registry 的**数据卷**（仓库、用户、run 历史、镜像 artifact 全灭）与 TF state——然后从 tar 备份恢复，全程分段计时输出 RTO。恢复后冒烟断言（Gitea 健康/仓库在/registry catalog/TF state 合法）证明"恢复"不是文件拷回，而是**世界复原**。

## What

- `backup_restore.sh` 五相：backup / destroy / restore / smoke / clean
- 备份三资产：Gitea 数据卷（lab25）、registry 卷（自动探测卷名）、TF state（labs/28 的期望态）
- `MANIFEST.md` 随备份生成：什么必须备份、什么可重建的清单文档
- RTO 分段计时：卷恢复/容器重建/state 还原/冒烟各阶段 + 总时长（实测 **10 秒**全恢复）

## When to Use

- 定期备份（cron 化 backup 相）+ 灾难演练季度化（destroy→restore 全流程）
- 新团队入职第一课：备份清单"什么必须备份、什么可重建"——区分这两类是灾备设计的第一性原理

## Quick Start

```bash
cd labs/29_backup_restore
./backup_restore.sh all    # 四相演练（约 1 分钟），RTO 分段计时
./backup_restore.sh backup # 单独备份
```

前置：labs/25 的 Gitea 卷、labs/14 的 registry（自动探测卷名）——都在就绪态时备份最有意义。

## How It Works

### 卷备份 = tar 容器化执行

```bash
docker run --rm -v lab25-gitea-data:/data -v $PWD/$TS_DIR:/backup alpine \
    tar czf /backup/gitea-data.tar.gz -C /data .
```

用 alpine 容器读写卷（宿主不直接碰 /var/lib/docker/volumes——那是 daemon 私有路径）。恢复是反向 tar。

### RTO/RPO

- **RTO**（恢复耗时目标）：脚本从 destroy 前打点，restore 各阶段与 smoke 各打点——本机实测全恢复 **10s**（生产数百 GB 卷另算，方法一致）
- **RPO**（可容忍数据丢失窗口）：本实验 backup 即最新态，RPO=0；生产场景 RPO=备份频率，须与业务容忍度对齐

## Pitfalls & Q&A

1. **[allowlist] 式的反向语义在这里也出现过**：registry 卷名不能写死（14 的卷名 lab-registry-data 与容器挂载可能不同）——`detect_reg_vol` 从容器 Mounts 动态探测。
2. **destroy 相删卷用 `-f`**：被容器引用的卷 rm 会拒绝，灾难演练要先 rm 容器再删卷——顺序错了"灾难"就演不成。
3. **恢复顺序**：先卷后容器（容器挂载不存在的卷会被 docker 自动创建空卷覆盖语义）；Gitea 数据卷恢复后容器起来 healthz 就绪约需 10s（数据库迁移）。
4. **备份文件完整性**：tar.gz 在网络/磁盘抖动下会截断（labs/25 教训同源）——本实验是本地卷 tar，无网络环节，但生产对象存储上传同样要校验 sha256。

## 产物清单

- `backup_restore.sh`：五相演练（backup→destroy→restore→smoke→clean），RTO 分段计时全绿
- `backups/<TS>/`：gitea-data.tar.gz + registry-data.tar.gz + terraform.tfstate + MANIFEST.md（运行时产物，clean 清理）
