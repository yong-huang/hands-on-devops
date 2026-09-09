// vars/hello.groovy — 共享库步骤：任何 Jenkinsfile 都能 devopslib.hello(name)
def call(String name) {
    echo "hello from shared library, ${name}!"
}
