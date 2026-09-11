# 07 · Molecule：给 Role 写真正的测试

> 实验 6 的 role 改一行 template，怎么知道没改坏？——拷到目标机跑一遍？生产不是试错场。
> Molecule 给 role 配一个"一次性容器靶场"：创建容器→应用 role→幂等断言→内容验证→销毁，
> 全程本地、全自动。从此配置代码享受单元测试待遇，红灯挡在合并之前。

## 1. 为什么需要它

没有测试的 role 是"盲盒"：

- template 改一个参数，只有目标机知道坏没坏；
- "改完在本地 vagrant 里试过"不可重复，也不进 CI；
- 幂等性靠自觉——没人会手动跑两遍 playbook 验证。

Molecule 把 role 的验收变成一条命令：`molecule test`。红的含义精确到断言，
绿的含义是"在干净容器里从头收敛、幂等、且结果符合期望"。

## 2. 总览：核心机制一图看懂

![molecule lifecycle](images/molecule_testing.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/07_molecule/images/molecule_testing.html)
> （或本地打开 [`images/molecule_testing.html`](images/molecule_testing.html)）。

看图方法：主轨道是 molecule test 的五幕。Idempotence 和 Verify 是两道闸门——
前者要求二次 converge `changed=0`，后者用 assert 检查配置内容与 HTTP 真实响应。
任何一道失败就是红灯（CI 阻断），修复后重跑回绿。

## 3. 快速开始

```bash
cd labs/07_molecule
./molecule_testing.sh test    # 完整五幕（真实输出见下）
./molecule_testing.sh break   # 故意写坏 role → 测试变红 → 修复 → 回绿
./molecule_testing.sh clean   # 清理测试容器
```

真实输出（test 全绿的红绿灯）：

```
SCENARIO RECAP
default : actions=12 successful=7 failed=0     # 语法/创建/收敛/幂等/验证/销毁 全绿
        [ok] 测试全绿

=====> [break] 故意写坏 role（端口 8080→8081）
default : actions=12 successful=6 failed=1     # verify 断言抓住端口不符 → 红灯
        [检出] 测试变红：断言抓住 'listen 8080' 缺失
=====> 修复回绿
default : actions=12 successful=7 failed=0
        [ok] 修复后回绿
```

## 4. 核心概念

### 4.1 场景（scenario）：测试环境的声明式描述

`molecule.yml` 三要素：**driver**（docker——测试容器怎么起）、**platforms**（什么镜像）、
**provisioner**（ansible 怎么连）。本实验用 `python:3.12-slim`——debian 系自带 bash 和
python3，天然满足 molecule 与 ansible 两个前提（踩坑记录见 §5）。

### 4.2 测试序列：五幕各管一件事

| 幕 | 干什么 | 失败意味着 |
|:---|:---|:---|
| create | 起 `webconf-instance` 容器 | 测试环境搭不起来 |
| converge | 对容器应用 role | role 本身跑不通 |
| idempotence | 再跑一遍 converge | **二次有 changed = 幂等破损** |
| verify | 跑 verify.yml 断言 | 结果不符合期望 |
| destroy | 销毁容器 | ——（收尾） |

idempotence 是 Molecule 的灵魂：它把实验 6 里"手动跑两遍看 changed"变成机器断言。

### 4.3 verify：断言"结果"而不只是"没报错"

```yaml
- ansible.builtin.assert:
    that:
      - "'app=molecule-demo' in (conf.content | b64decode)"   # 文件内容
- ansible.builtin.uri: { url: "http://127.0.0.1:8080/healthz", return_content: true }
      # HTTP 层：服务真在响应，healthz 返回 200 且内容正确
```

三层递进：文件在（stat）→ 内容对（slurp+assert）→ 服务活着（uri）。
本实验做到第三层——nginx 装好、配置对、healthz 真的返回 200。

### 4.4 红灯演示：测试的价值在"能红"

`./molecule_testing.sh break` 把模板端口改成 8081——语法完全正确、converge 照样成功，
但 verify 的断言 `'listen 8080' in conf` 失败，molecule 退出码非零。**这正是 CI 要的**：
"role 能跑"和"role 跑对了"是两回事，断言替你盯着后者。

## 5. YAML 关键字段

```yaml
platforms:
  - name: webconf-instance
    image: python:3.12-slim    # 坑①②：alpine 没有 bash；debian 系才有 apt
    pre_build_image: true      # 直接用现成镜像，测试里不 docker build
provisioner:
  env:
    ANSIBLE_ROLES_PATH: "${MOLECULE_PROJECT_DIRECTORY}/../"   # 坑③：role 搜索路径
```

坑清单（全部真实踩过）：

- **坑① alpine 没有 bash**：molecule docker driver 默认用 bash 进容器，
  `exec: "bash": executable file not found`——换 `-slim`/debian 系镜像；
- **坑② 镜像变 debian 后 role 也要变**：apk → apt 模块（apt 原生幂等，
  比 `command + creates` 更干净）；
- **坑③ role 路径**：场景在 role 内部（`roles/webconf/molecule/`）时必须设
  `ANSIBLE_ROLES_PATH`，否则 `The role 'webconf' was not found`；
- **坑④ 幂等安装**：`command: apk add` 每次都 changed——用 apt 模块或
  `args: { creates: /usr/sbin/nginx }` 护栏；
- **坑⑤ 容器里的 nginx**：没有 systemd，reload handler 要写
  `nginx -t && (nginx -s reload || nginx)`。

## 6. 文件结构

```
07_molecule/
├── README.md                            # 本教程
├── molecule_testing.sh                  # test / break / clean 三步演示
└── roles/webconf/                       # 被测 role（含测试场景）
    ├── tasks/main.yml                   # apt 装 nginx → template → nginx -t
    ├── handlers/main.yml                # reload（容器内无 systemd 的写法）
    ├── templates/app.conf.j2            # 被渲染的站点配置
    ├── defaults/main.yml                # app_name/app_env
    └── molecule/default/
        ├── molecule.yml                 # driver/platforms/provisioner 声明
        ├── converge.yml                 # "应用 role"的播放本
        └── verify.yml                   # 断言：内容 + HTTP + 语法
```

## 7. 深入要点

- **Molecule 的 test sequence 有哪些阶段？** dependency → lint → syntax → create →
  prepare → converge → idempotence → side_effect → verify → cleanup → destroy；
  核心是 converge/idempotence/verify 三步。
- **idempotence 测试的原理？** 连跑两遍 converge 对比结果：第二遍必须全部 ok、
  changed=0——凡是"每次都 changed"的 task（command 裸跑等）都会被抓。
- **verify.yml 和 converge.yml 的分工？** converge 表达"怎么应用"，verify 表达
  "应用后世界应该是什么样"——前者是动作，后者是断言。
- **配置测试怎么进 CI？** PR 触发 `molecule test`，非零退出阻断合并；
  测试容器即用即弃，不污染 runner（实验 18 起的流水线都能挂）。
- **测试容器的选择原则？** 贴近生产目标发行版 + 满足 driver/ansible 运行前提
  （bash、python3）；pre_build_image 复用现成镜像，测试不背构建成本。

## 8. 总结

到这里，Ansible 的工程闭环齐了：role（写）→ Molecule（测）→ 靶场（用）。
第二阶段还剩三代"老牌"配置管理：实验 8 的 Salt（masterless 声明式）、实验 9 的
Chef + InSpec（cookbook + 合规扫描）、实验 10 的 Puppet（agent 拉取模型）——
每一代都和 Ansible 对照着看，四种哲学一次看清。
