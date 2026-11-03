package main

# 可观测性与归属的最低要求：没有 label 的负载出了问题找不到人
deny contains msg if {
    input.resource.kind == "Deployment"
    not input.resource.metadata.labels.app
    msg := "Deployment is missing required label 'app'"
}

deny contains msg if {
    input.resource.kind == "Deployment"
    not input.resource.metadata.labels.team
    msg := "Deployment is missing required label 'team'"
}
