# SPL 速查卡（实验 03 产出 · 唯一事实源）

> 面向 tutorial 数据集（sourcetype=access_combined_wcookie）的 14 条 SPL。每条都在
> ```spl 代码围栏里，`spl_run.sh` 从本文件提取并经 REST 逐条执行断言——卡片改一条，
> 验收跟着变，不需要维护两份。
> 约定：# 开头的行是给人看的注释，提取时剥掉；一条围栏 = 一条完整 SPL。

## 一、时间控制

### 1. 宽时间窗基线（earliest/latest 的完整写法）

```spl
index=tutorial sourcetype=access_combined_wcookie earliest=-10y latest=now | stats count
```

### 2. 绝对时间写法（教程事件固定在 2026-11-07）

```spl
index=tutorial earliest=11/07/2026:00:00:00 latest=11/08/2026:00:00:00 | stats count
```

### 3. 布尔组合（OR / AND / NOT）

```spl
index=tutorial sourcetype=access_combined_wcookie (status=404 OR status=500) NOT action=purchase | stats count
```

## 二、字段选择

### 4. fields 提取（进管道前瘦身，内部优化友好）

```spl
index=tutorial sourcetype=access_combined_wcookie | fields clientip, status | head 5
```

### 5. table 展示（直接决定输出列）

```spl
index=tutorial sourcetype=access_combined_wcookie | table _time, clientip, action, status | head 10
```

### 6. rename 改名（输出可读性）

```spl
index=tutorial sourcetype=access_combined_wcookie | rename clientip AS client_ip | table client_ip, status | head 5
```

## 三、结果整形

### 7. sort 按时间倒序

```spl
index=tutorial sourcetype=access_combined_wcookie | sort -_time | table _time, clientip, status | head 5
```

### 8. tail 取末尾（对照 head）

```spl
index=tutorial sourcetype=access_combined_wcookie | tail 5
```

### 9. dedup 去重（默认保留第一条）

```spl
index=tutorial sourcetype=access_combined_wcookie | dedup clientip | stats count
```

## 四、eval 计算字段

### 10. eval 算术（bytes 换算 KB）

```spl
index=tutorial sourcetype=access_combined_wcookie | eval bytes_kb=round(bytes/1024,1) | table bytes, bytes_kb | head 5
```

### 11. eval 条件分类（if 三参写法）

```spl
index=tutorial sourcetype=access_combined_wcookie | eval 状态=if(status>=500,"服务端错","其他") | stats count by 状态
```

## 五、where 过滤

### 12. where 直接比较（作用于字段，写在管道中段）

```spl
index=tutorial sourcetype=access_combined_wcookie | where bytes > 4000 | stats count
```

### 13. eval + where 组合①（算出衍生量再过滤）

```spl
index=tutorial sourcetype=access_combined_wcookie | eval size_mb=round(bytes/1024/1024,2) | where size_mb > 0 | stats avg(bytes) as avg_bytes
```

### 14. eval + where 组合②（标记后再筛）

```spl
index=tutorial sourcetype=access_combined_wcookie | eval is_error=if(status>=400,1,0) | where is_error=1 | stats count by status
```
