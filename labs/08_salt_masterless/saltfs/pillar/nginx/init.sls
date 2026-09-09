# =============================================================================
# pillar/nginx/init.sls — 按 grain 的 env 取值：同一份配置，环境不同数据不同
# =============================================================================
{% set env = grains.get('env', 'dev') %}

app_name: salt-masterless-lab
app_env: {{ env }}

{% if env == 'staging' %}
greeting: hello from STAGING
workers: 2
{% else %}
greeting: hello from dev
workers: 1
{% endif %}
