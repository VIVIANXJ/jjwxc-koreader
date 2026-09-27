# 贡献指南

感谢参与改进 JJWXC for KOReader。

## 基本原则

- 不要提交任何真实账号、Token、Cookie、密码、已购正文、段评缓存或生成的 EPUB。
- 不要加入绕过购买、权限控制、验证码或账号限制的功能。
- 保持标准 KOReader 菜单可独立工作；Simple UI 必须始终是可选集成。
- Lua 代码需兼容 Lua 5.1。
- 网络任务应有超时、可取消，并尽量减少电子墨水屏的频繁刷新。
- 修改登录、VIP 解密、下载或缓存逻辑时，请说明测试范围和数据保护影响。

## 提交前检查

```sh
./scripts/check.sh
./scripts/package.sh
```

Pull Request 请包含变更目的、测试设备/KOReader 版本、验证步骤及界面截图（如适用）。截图必须脱敏。
