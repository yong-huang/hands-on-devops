# =============================================================================
# 07 · Python 对照 —— 与 01 的 TS 版同题重写
#
# 同一份题面：自定义网络 + nginx 容器 + url 输出（与 ../../01_docker_provider/
# program/index.ts 逐行并读）。两种语言、同一个引擎、同一种账本——资源声明的
# 写法随语言变，期望态模型与 state 结构不变。
#
# 运行入口是 ../python_parity.sh（parity 段会把 TS 版拉起来做 export 对比）。
# =============================================================================
import pulumi
import pulumi_docker as docker

# TS: const appName = "pulumi01";      PY: 项目名就是现成的命名前缀
project = pulumi.get_project()

# TS: const port = 28081（写死在程序里）;  PY: 走配置——两个栈天然不撞端口
config = pulumi.Config()
port = config.get_int("port") or 28511

# TS: new docker.Network("net", { name: `${appName}-net` })
# PY: 类同名，参数从对象字面量换成 kwargs；f-string 对应模板字符串
net = docker.Network("net", name=f"{project}-net")

# TS: ports: [{ internal: 80, external: 28081 }]
# PY: 每个复杂属性是一个 *Args 类；camelCase 换成 snake_case
app = docker.Container(
    "app",
    name=f"{project}-nginx",
    image="nginx:1.27-alpine",
    ports=[docker.ContainerPortArgs(internal=80, external=port)],
    networks_advanced=[docker.ContainerNetworksAdvancedArgs(name=net.name)],  # 同一条依赖边
)

# TS: pulumi.interpolate`...`     PY: port 是普通 int，f-string 就够
pulumi.export("url", f"http://localhost:{port}/")
# Output 的流动两语言同构：net.name 传进 networks_advanced，依赖边自动成立
pulumi.export("container_name", app.name)
