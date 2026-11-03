package main

# 特权容器 = 宿主级风险面（fd 挂载/内核能力全开）——一律阻断
deny contains msg if {
    input.resource.kind == "Deployment"
    some container in input.resource.spec.template.spec.containers
    container.securityContext.privileged == true
    msg := sprintf("Container '%s' must not run privileged", [container.name])
}
