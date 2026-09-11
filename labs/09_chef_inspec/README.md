# 09 · Chef + InSpec：配置收敛 + 合规扫描双闭环

> Chef 把配置写成 Ruby 代码——程序员味最重的一代；InSpec 更进一步，把"验收标准"也写成
> 代码：每条 control 是一条可执行的合规需求，`inspec exec` 的退出码直接当 CI 门禁。
> 本实验在一个 debian 容器里跑通双闭环：收敛 nginx → 扫描 5 条基线 → 红灯 → 整改 → 全绿。

## 1. 为什么需要它

运维脚本时代的问题在 Chef 出现的 2009 年就成立，今天依然成立：

- shell 脚本描述"步骤"，Chef/Ansible/Salt 描述"结果"——结果才能幂等、才能 diff；
- 但"配置收敛成功"≠"系统合规"：版本号泄露、弱配置、缺基线，收敛工具不管——
  InSpec 这类"合规即代码"工具补上这一环（实验 22 的 OPA 是它的策略即代码表亲）。

## 2. 总览：核心机制一图看懂

![chef inspec](images/chef_inspec.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/09_chef_inspec/images/chef_inspec.html)
> （或本地打开 [`images/chef_inspec.html`](images/chef_inspec.html)）。

看图方法：左闭环是收敛——cookbook（recipe+模板）经 chef-client 本地模式驱动节点资源；
右闭环是合规——InSpec 对节点跑 5 条 control，产出报告。退出码非零 = 有失败 = 门禁拦截。

## 3. 快速开始

```bash
cd labs/09_chef_inspec
./chef_inspec.sh            # 环境 → converge → 扫描(4过1败) → 整改 → 全绿 → 清理
./chef_inspec.sh fix        # 单独重放整改闭环
```

真实输出（关键节点）：

```
=====> [inspec] 首次合规扫描（预期 4 通过 / 1 失败）
        Profile Summary: 4 successful controls, 1 control failure
        [检出] InSpec 退出码 100 —— webapp-05 失败即'合规红旗'
=====> [fix] 整改：模板加 server_tokens off → 重收敛 → 重扫描
        Profile Summary: 5 successful controls, 0 control failures
        [ok] 合规整改闭环：失败控件 → 改模板 → 收敛 → 全绿
        宿主机验证：app=chef-lab env=dev
```

## 4. 核心概念

### 4.1 recipe：Ruby 写的声明式资源

```ruby
template '/etc/nginx/conf.d/app.conf' do
  source 'app.conf.erb'
  variables app_name: 'chef-lab', app_env: 'dev'
  notifies :run, 'execute[reload-or-start-nginx]'   # ≈ Ansible 的 notify
end

execute 'reload-or-start-nginx' do
  command 'nginx -t && (nginx -s reload 2>/dev/null || nginx)'
  action :nothing                                    # 只被通知触发 ≈ handler
end
```

与 Ansible 的概念一一对应，但表达力来自 Ruby：可以写循环、条件、甚至自定义资源——
代价是"代码即配置"也意味着"代码的复杂度问题会回来"。

### 4.2 chef-client --local-mode：无 server 的本地收敛

Chef 的完整形态是 chef-server + client 拉取；`--local-mode`（原 chef-solo）直接读本
地 cookbook 收敛本机。和实验 8 的 masterless Salt 同一思路：**先掌握"收敛"本体，
中心化只是规模工具**。

### 4.3 InSpec control：可执行的验收标准

```ruby
control 'webapp-05 server tokens off' do
  impact 0.6                                    # 严重度：0~1，门禁可按 impact 过滤
  title '安全基线：隐藏 nginx 版本号'
  describe file('/etc/nginx/conf.d/app.conf') do
    its('content') { should match /server_tokens off;/ }
  end
end
```

5 条 control 覆盖四层：包已装（package）→ 配置对（file+content）→ 端口听（port）→
服务活（http）。失败的 control 让 `inspec exec` 退出码非零——这就是"合规即门禁"。

### 4.4 整改闭环（本实验的叙事主线）

红灯（webapp-05 失败）→ 修模板加 `server_tokens off;` → 重新收敛 → 重扫描全绿。
注意闭环的顺序：**改的是 cookbook（源码），不是节点上的配置**——节点只是收敛的产物。

## 5. 关键字段

```ruby
execute 'reload-or-start-nginx' do
  command 'nginx -t && (nginx -s reload 2>/dev/null || nginx)'
  action :nothing                       # 默认不执行，只等 notifies
end
```

坑清单（全部真实踩过，arm64 mac 视角）：

- **坑① chef/chef 官方镜像已坏**：alpine 底座 + glibc 链接的 ruby →
  `librt.so.1: cannot open shared object file`（amd64/arm64 双双阵亡）。
  解法：debian 容器 + omnitruck 官方 deb（arm64 原生支持）+ docker commit 缓存；
- **坑② chef-client 需接受 license**：`CHEF_LICENSE=accept-silent`（inSpec 同理），
  而且 `docker exec` 传环境变量必须用 `-e`，写成 `docker exec C VAR=val cmd` 会把
  `VAR=val` 当可执行文件；
- **坑③ omnitruck 安装脚本缺 perl 模块**：debian 需先 `apt install libwww-perl`；
- **坑④ inspec 不在 PATH**：deb 装完后用全路径 `/opt/chef/bin/inspec` 最稳。

## 6. 文件结构

```
09_chef_inspec/
├── README.md                              # 本教程
├── chef_inspec.sh                         # env/apply/fix/clean 四步演示
├── cookbooks/webapp/
│   ├── metadata.rb                        # cookbook 身份声明
│   ├── recipes/default.rb                 # 资源声明（package/template/execute）
│   └── templates/default/app.conf.erb     # ERB 模板（整改对象）
├── profiles/webapp/
│   ├── inspec.yml                         # 合规档案元数据
│   └── controls/webapp.rb                 # 5 条 control（安装/配置/端口/健康/基线）
└── images/                                # 图三件套（json/html/svg）
```

## 7. 深入要点

- **Chef 的核心抽象？** resource（幂等资源声明）→ recipe（资源编排）→ cookbook（分发
  单元）→ run_list（节点应用哪些 recipe）；compile 阶段生成资源集合，converge 阶段执行。
- **InSpec 与传统扫描器（Nessus 等）的区别？** InSpec 是"期望态断言"（可执行的需求、
  可进 git、可当门禁），扫描器是"已知漏洞库匹配"。前者定义该怎样，后者发现哪里坏了。
- **合规即代码怎么落地到流水线？** control 集作为制品纳入 review；CI 在部署后自动
  `inspec exec`，impact>=0.5 失败即回滚（实验 25 的三道门之一）。
- **Chef 的 Ruby DSL 是优势还是负担？** 优势：复杂逻辑可编程、可抽象出库（LWRP/HWRP）；
  负担：运维需会编程、review 难度上升。这也是后来 YAML 系（Ansible）流行的原因。
- **容器时代还需要 Chef 吗？** 镜像构建期（Packer/Dockerfile + Chef/Ansible provisioner）
  仍在用；运行期配置逐渐下沉到不可变镜像 + K8s 控制器（实验 12 会在 Packer 里复用 role）。

## 8. 总结

四代配置管理已经历三代：Ansible（YAML push）、Salt（YAML pull/push 双模）、
Chef（Ruby pull）。实验 10 补上最后一块拼图 Puppet——最老牌的声明式 DSL，agent 拉取
模型的原型机，并给出四代总对比表的最终版。
