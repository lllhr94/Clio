# 内置宠物包

每个宠物放在独立目录 `Pets/<id>/`。目录里放 schema 1 的 `pack.json` 和它引用的 PNG，可用 `tools/make_pet_pack.py` 生成。

目录名用于保存宠物选择。更新同一只宠物时保留目录名，App 会为它保留独立于用户导入包的标识。
