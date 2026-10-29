from setuptools import setup

setup(
    name="handson-plugin",
    version="0.1.0",
    description="Hands-on Cloudify plugin: http check, rendered file (dsl_1_5)",
    packages=["handson_plugin"],
    install_requires=["requests"],
)
