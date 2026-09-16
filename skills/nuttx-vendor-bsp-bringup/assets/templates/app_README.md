# <command name>

<One sentence: which peripheral path this command validates.>

## 依赖

- 设备节点：`/dev/<node>`
- 需要的 Kconfig：`CONFIG_<...>=y`
- 相关框架/后端：<e.g. input upper half / MTD registry / netdev>

## 测试步骤

```text
nsh> ls /dev
/dev/<node> must be present

nsh> <command> <default args>
```

## 预期结果

<Concrete, observable output. Include the exact PASS line to look for.>

```text
<command>: PASS; <what was proven>
```

## 判定标准

| 检查项 | 通过条件 |
|--------|----------|
| <e.g. identity> | <e.g. product ID / JEDEC ID matches> |
| <e.g. data path> | <e.g. two reads share one CRC32> |
| <e.g. persistence> | <e.g. file survives reboot> |
| <e.g. interrupt> | <e.g. `irq > 0` in the close log> |

## 实测结果

- <date / build or image hash>: <what was actually observed on the board>

## 已知限制

- <e.g. only one reader allowed; must close the diagnostic command first>
- <e.g. shares a pin with <other function>; mutually exclusive>
- <e.g. not yet verified: <aspect>>
