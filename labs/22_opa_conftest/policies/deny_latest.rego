package main

deny contains msg if {
    input.resource.kind == "Deployment"
    some container in input.resource.spec.template.spec.containers
    endswith(container.image, ":latest")
    msg := sprintf("Container '%s' uses :latest tag", [container.name])
}

deny contains msg if {
    input.resource.kind == "Deployment"
    some container in input.resource.spec.template.spec.containers
    not container.resources
    msg := sprintf("Container '%s' has no resource limits", [container.name])
}

warn contains msg if {
    input.resource.kind == "Deployment"
    some container in input.resource.spec.template.spec.containers
    not container.securityContext.runAsNonRoot
    msg := sprintf("Container '%s' does not run as non-root", [container.name])
}
