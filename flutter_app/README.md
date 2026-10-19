# 故人 · Flutter 客户端

“故人”的客户端工程，一套代码同时出 Windows 和 Android 两端


客户端所有请求都走一个 HTTP baseUrl

- **App 内置后端**（`lib/backend/`）：用 `dart:io HttpServer` 跑在 App 进程里，监听 `127.0.0.1`
  手机端默认，装完即用、不用连电脑
  纯 Dart 实现，**没有截图 OCR**
- **Python 后端**（仓库根的 `server/` + `validator/`）：功能完整，带离线 OCR
  桌面版打包时把它做成 exe 放进 `server/` 目录，App 启动时拉起；也可以自己单独跑

两套后端的 JSON 契约和数据目录布局一致（都写 `guren-data/`），改接口时两边要同步改

## 目录

```
lib/
  main.dart            入口 + provider + 路由
  theme.dart           微信式主题（亮/暗）
  models.dart          数据模型（严格对齐 server/main.py 的 JSON）
  api.dart             API 客户端（全部端点）
  state.dart           AppState（连接配置、人物列表、持久化、内置后端启动）
  chat_import.dart     聊天导出文本解析（「名字 时间」/「名字：内容」）
  widgets.dart         头像 / 气泡 / AI 声明条
  backend/             内置后端：llm / schema / presets / scheduler
                       / store / dispatcher / engine / distill / server
  screens/
    splash.dart        启动：健康检查 + 拉内置后端
    settings.dart      连接与设置
    characters.dart    人物列表（桌面双栏 / 手机单栏）
    chat.dart          聊天（引用 / 立即模式 / 延迟轮询 / 主动发起 / 时间表）
    distill.dart       蒸馏向导（导入 → 蒸馏 → 校准）
    persona_detail.dart 人格档案详情（特质 / 缺点 / 关系 / 蒸馏报告）
    preset_create.dart 性格标签组合创建
```

## 数据位置

| 平台 | 位置 |
|---|---|
| Windows | exe 同级的 `guren-data/` |
| Android | App 私有目录下的 `guren-data/`（卸载会一起清掉） |
