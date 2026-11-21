# Clio 备份格式（公开，任何平台的客户端都能读）

文件名：`Clio 备份 <yyyy-MM-dd HHmm>.clio-backup`。网盘备份放在 WebDAV 根目录下的 `Clio/` 文件夹。

## 外层

```
"CLIO-BACKUP-1\n"                      14 字节的标记
重复到文件结束：
  名字长度   UInt32，大端
  名字       UTF-8，相对路径（见下）
  内容长度   UInt64，大端
  内容       原样字节
```

没有压缩、没有加密，任何语言几十行就能读写（参照 `App/Sources/Care/Backup.swift`）。

## 里面有什么

| 名字 | 内容 |
|---|---|
| `Team/bots.json` | 旅伴：名字、性格（`temper`）、说话方式（`style`）、朱印字（`seal`）、设定、模型、头像 |
| `Team/rooms.json` | 雅集（群聊）和成员 |
| `Team/settings.json` | 模型服务（地址、模型列表、能力修正、服务报的上下文长度）、默认模型等；**不含密钥** |
| `Team/memory.json` | 常记和旧事 |
| `Team/routines.json` | 定时任务 |
| `Team/hills.json`、`Team/mcp.json`、`Team/mcp-tools.json` | 远程主机、MCP 服务（不含密码） |
| `Team/secrets.json` | 信匣里**各项的名字和说明**；值只在钥匙串里，**永远不进备份** |
| `Team/chats/<对话>.json` 等 | 每段对话的消息；`~summary.json` 是压缩后的前情提要，`~options.json` 是这段对话的设置 |
| `Team/media/<编号>` | 对话里的图片 |
| `Team/diary/…` | 手札 |
| `Portraits/…` | 旅伴的照片头像 |
| `#settings` | 外观、对话等偏好（plist） |
| `#keys` | 只在用户勾了「备份里带上密钥」时才有：各模型服务的 API 密钥（JSON） |

**不在备份里的**（0.34 审查 #6）：书案的文件（Documents，用「文件」App 拷）、自己导入的宠物包、没发出的草稿、钥匙串里的信匣和主机密码。

恢复时先把整个文件校验一遍、写进旁边的副本，成功后才替换现有数据（失败时原样不动），只写回 `Team/` 和 `Portraits/` 下的文件（路径里不能有 `..`），其余忽略。

## 以后的客户端

安卓、鸿蒙、电脑、网页版的 Clio 读这个格式即可接上同一份数据；格式变动时把标记升成 `CLIO-BACKUP-2`，老版本读到新标记要明说「版本太新」而不是乱读。
