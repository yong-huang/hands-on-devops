# 06 · Ansible 深水区：动态清单 + Role + Vault 的 push 模型

> 实验 5 的靶场 nginx 还带着镜像默认配置。本实验用 Ansible 给它部署站点配置——但不是
> adhoc 命令：动态清单自动发现容器、role 固化可复用逻辑、Vault 加密密钥变量、幂等可重复。
> 这四个词就是"Ansible 工程化"与"会跑 playbook"的分界线。

## 1. 为什么需要它

散装 playbook 的三个通病：

- 主机写死在 inventory 文件里——容器一重建 IP/名字全变；
- 敏感值（token/密码）明文躺在 group_vars 里——git 仓库成了密码泄露现场；
- task 平铺不可复用——下一个项目要同样的 nginx 配置，又复制一遍。

Role 解决复用，动态清单解决"目标从哪来"，Vault 解决"密钥怎么进 git"。

## 2. 总览：核心机制一图看懂

![ansible role vault](images/ansible_role_vault.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/06_ansible_role_vault/images/ansible_role_vault.html)
> （或本地打开 [`images/ansible_role_vault.html`](images/ansible_role_vault.html)）。

看图方法：动态清单查出 lab-nginx → playbook 调用 role → 模板渲染时从 Vault 密文注入
token → 经 `docker exec` 写进靶场容器。手工改动（右下）会被下一次 playbook 运行覆盖自愈。

## 3. 快速开始

```bash
make lab-up                                  # 靶场先就位（实验 05）
cd labs/06_ansible_role_vault
./ansible_role_vault.sh                      # apply → 幂等 → 漂移 → vault → 还原
./ansible_role_vault.sh idempotent           # 单独验证幂等
```

真实输出（三次执行的关键指标）：

```
=====> [apply]       首次部署
lab-nginx : ok=5 changed=1 unreachable=0 failed=0
=====> [idempotent]  立即重跑
lab-nginx : ok=4 changed=0 unreachable=0 failed=0
        [ok] changed=0，幂等达成
=====> [drift]       手动破坏容器内配置 → 重跑 → 自愈
        [ok] 配置已被 role 修复（漂移检出与回正一体）
```

## 4. 核心概念

### 4.1 动态清单：目标是查出来的

`inventory/docker.docker.yml`（文件名后缀必须匹配插件名，见坑②）：

```yaml
plugin: community.docker.docker_containers
connection_type: docker-cli          # 走 docker exec，不需要 ssh/目标机 agent
groups:
  web: "'lab-nginx' in docker_name"  # Jinja 条件分组
```

`ansible-inventory --graph` 真实输出：靶场四个容器全部自动入列，`lab-nginx` 落进 `web` 组。
靶场扩容/重建，清单自动跟上——这就是"动态"的含义。

### 4.2 Role：目录即接口

`roles/webconf/` 遵循标准布局：`tasks/`（做什么）、`handlers/`（配置变了才 reload）、
`templates/`（Jinja2 模板）、`defaults/`（可覆盖的默认参数）、`meta/`。幂等三件套：

| 手段 | 作用 |
|:---|:---|
| `template` 模块 | 内容级比较：内容没变就不动 |
| `notify: reload nginx` | handler 只在模板真变化时执行 |
| `changed_when: false` | command 校验类操作不计入 changed |

### 4.3 Vault：密文的 git 工作流

```bash
ansible-vault encrypt group_vars/all/vault.yml   # 口令来自 tmp/vault-pass
ansible-playbook playbook.yml                    # 运行时自动解密渲染
```

真实取证：密文文件里 `grep tok-*` 零命中；容器里 `grep` 渲染产物命中——**密钥原文只存在
于两处：Vault 密文和运行时内存，永远不进 git**。轮换演示：解密→改值→加密→重跑，
模板 changed 触发 handler reload，新 token 立即生效。

### 4.4 push 模型

Ansible 是 push：控制机主动 SSH/exec 到目标执行，目标不需要常驻 agent。
对照实验 8（Salt masterless）、实验 10（Puppet agent 拉取）时会反复回到这张图。

## 5. YAML 关键字段

```yaml
- name: 确保目标有 python3          # 坑①的修复，详见下文
  ansible.builtin.raw: "test -e /usr/bin/python3 || apk add --no-cache python3"
  changed_when: false               # raw 不判断幂等，必须显式收敛

- name: 渲染站点配置（vault 变量在此参与渲染）
  ansible.builtin.template:
    src: site.conf.j2
    dest: /etc/nginx/conf.d/site.conf
  notify: reload nginx              # 变化才触发
```

坑清单（全部真实踩过）：

- **坑① alpine 容器没有 python3**：template 等模块报 `/usr/bin/python3: not found`。
  先用 `raw` 模块（裸 shell，不依赖 python）装 python3，并用 `test -e ||` 保证幂等；
- **坑② 动态清单文件名**：插件 verify 只认 `*.docker.yml` 后缀——命名成
  `docker_containers.yml` 会被 yaml/ini 插件抢着解析然后失败；
- **坑③ 第三方清单插件要显式启用**：`ansible.cfg` 的 `[inventory] enable_plugins`
  必须包含 `community.docker.docker_containers`，否则 auto 插件报 "could not be verified"；
- **坑④ 插件变量名**：分组条件里的变量是 `docker_name` 不是 `name`（猜错分组为空，
  playbook 静默 skip，一个字都不报）；
- **坑⑤ bash 变量后接全角字符**：`$cur（vault…）` 会把多字节字符吃进变量名报
  unbound variable——必须 `${cur}` 花括号隔离。

## 6. 文件结构

```
06_ansible_role_vault/
├── README.md                        # 本教程
├── ansible_role_vault.sh            # 主演示脚本：apply/idempotent/drift/vault/clean
├── ansible.cfg                      # 清单/vault 口令文件/回调配置
├── playbook.yml                     # role 调用入口
├── inventory/
│   └── docker.docker.yml            # 动态清单（docker_containers 插件）
├── group_vars/all/
│   ├── vars.yml                     # 明文变量
│   └── vault.yml                    # ansible-vault 加密后入库
├── roles/webconf/
│   ├── tasks/main.yml               # 装python3 → 渲染 → 校验 → 探活
│   ├── handlers/main.yml            # reload nginx（被通知才跑）
│   ├── templates/site.conf.j2       # 站点配置模板（token 注入）
│   └── defaults/main.yml            # 站点名等默认参数
├── tmp/                             # vault 口令文件（gitignore，绝不提交）
└── images/                          # 图三件套（json/html/svg）
```

## 7. 深入要点

- **幂等怎么实现？** 模块化设计：每个模块知道如何读取当前状态并只在偏离期望时改动；
  command/shell 这类"哑模块"靠 changed_when/creates 手工声明幂等语义。
- **handler 和普通 task 的区别？** handler 由 notify 事件驱动、一轮 play 末尾去重执行
  一次——天然防止"改 3 个文件 reload 3 次"。
- **动态清单适用场景？** 目标集合随时间变化的基础设施（容器、 autoscaling 组、
  cloud API）；代价是清单数据要在目标"活着"时可查。
- **Vault 与密管系统的边界？** Vault 解决"密钥静态入库"，但不解决动态分发、轮换审计、
  过期控制——那是 Vault/云 KMS 的领域（实验 24 对比选型）。
- **push vs pull 的取舍？** push 即时、无 agent、控制机单点；pull 定时收敛、目标规模
  无控制机瓶颈、天然抗控制机故障（Puppet/Salt 系）。

## 8. 总结

Ansible 把"配置怎么写"工程化了：role 复用、清单动态、密钥加密、幂等可验证。
但 role 本身没被测试——改坏 template 要到目标机上才发现。实验 7 引入 Molecule：
给 role 写真正的测试（创建容器→应用→幂等断言→验证→销毁），让配置代码享受单元测试待遇。
