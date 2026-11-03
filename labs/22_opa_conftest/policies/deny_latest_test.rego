package main

# 策略自身的单元测试：conftest verify -p policies/ 执行
# 策略是代码——代码要有测试，门禁才可信。

latest_input := {
    "resource": {"type": "kubernetes", "kind": "Deployment",
        "metadata": {"labels": {"app": "web", "team": "platform"}},
        "spec": {"template": {"spec": {"containers": [
            {"name": "web", "image": "nginx:latest",
             "resources": {"limits": {"cpu": "100m"}},
             "securityContext": {"runAsNonRoot": true}}]}}}}
}

good_input := {
    "resource": {"type": "kubernetes", "kind": "Deployment",
        "metadata": {"labels": {"app": "web", "team": "platform"}},
        "spec": {"template": {"spec": {"containers": [
            {"name": "web", "image": "nginx:1.27",
             "resources": {"limits": {"cpu": "100m"}},
             "securityContext": {"runAsNonRoot": true}}]}}}}
}

privileged_input := {
    "resource": {"type": "kubernetes", "kind": "Deployment",
        "metadata": {"labels": {"app": "web", "team": "platform"}},
        "spec": {"template": {"spec": {"containers": [
            {"name": "web", "image": "nginx:1.27",
             "resources": {"limits": {"cpu": "100m"}},
             "securityContext": {"privileged": true}}]}}}}
}

no_labels_input := {
    "resource": {"type": "kubernetes", "kind": "Deployment",
        "spec": {"template": {"spec": {"containers": [
            {"name": "web", "image": "nginx:1.27",
             "resources": {"limits": {"cpu": "100m"}},
             "securityContext": {"runAsNonRoot": true}}]}}}}
}

test_good_deployment_has_no_denies if {
    msgs := [m | some m in deny with input as good_input]
    count(msgs) == 0
}

test_latest_tag_denied if {
    msgs := [m | some m in deny with input as latest_input]
    some m in msgs
    contains(m, "uses :latest tag")
}

test_good_image_not_denied_for_latest if {
    msgs := [m | some m in deny with input as good_input]
    latest_msgs := [m | some m in msgs; contains(m, "uses :latest tag")]
    count(latest_msgs) == 0
}

test_privileged_denied if {
    msgs := [m | some m in deny with input as privileged_input]
    some m in msgs
    contains(m, "must not run privileged")
}

test_missing_labels_denied_twice if {
    msgs := [m | some m in deny with input as no_labels_input]
    count(msgs) == 2
}
