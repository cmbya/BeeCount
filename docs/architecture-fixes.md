# 架构审查问题修复说明

## 本轮范围

本次只修复已确认的数据一致性、预算刷新、数据库迁移/索引、保存反馈与记账日志问题。
不改动 iOS AppIntent 交互、不改账户/分类/标签来源；AI 密钥同步和缺汇率统计口径按用户要求暂缓。

- 交易及其同步变更记录在同一事务提交；失败时一起回滚。
- 手动收支、转账和 AI 账单创建的标签保存与账单同事务；不吞掉标签写入错误。
- 附件记录及父交易同步变更保持原子；部分图片失败只提示补图，不要求重记账。
- 已提交后的缓存、同步、小组件和提示异常不再被输入框当成保存失败；提交期间阻止重复点击。
- 删除账单时先原子更新数据库，只在最外层事务成功后清理无引用图片；回滚不能删除仍有效的图片。
- 数据库 v36 统一新建/升级索引，并在升级事务内更新版本；旧 v27 已添加列时可安全重入。
- 交易后处理刷新预算缓存；账单创建服务日志不再输出金额、分类名、账户名、备注和标签内容，相关 AI 保存异常仅记录异常类型。
- 金额为 NaN 或正负无穷时拒绝入库；不修改有效金额、币种或缺汇率处理规则。

## 回归用例（已编写，不代表已运行）

- `test/data/repositories/local_repository_atomic_write_test.dart`
- `test/data/after_successful_transaction_test.dart`
- `test/data/repositories/transaction_delete_cleanup_test.dart`
- `test/data/migration_v36_test.dart`
- `test/services/billing/post_processor_budget_test.dart`
- `test/services/billing/bill_creation_service_test.dart`
- `test/services/attachment_service_test.dart`
- `test/services/ai/ai_bookkeeper_test.dart`
- `test/widgets/amount_editor_submit_test.dart`
- `test/widgets/transaction_editor_atomic_test.dart`
- `test/widgets/transfer_form_atomic_test.dart`

## 验证边界

用户要求本轮不执行或查询 GitHub Actions，不追加远程提交核验。
因此本轮仅做源码/差异静态复核，未运行 Flutter 测试、Dart analyzer、格式化工具或 iOS/Android 编译。
未安装依赖、未在飞牛上克隆仓库、未生成安装包或发布 Release。
旧版金额/备注输入导致快捷指令终止的问题仍需单独真机验收；不能据此文档声称已经解决。

## 已知边界

- 文件清理回调在内存中登记。若进程在数据库提交后、文件清理前终止，可能留下无引用文件，可由已有维护扫描处理；不会因此回滚已提交的账单。
- 原有持久日志未清理；此次仅减少后续记账日志中的敏感内容，不宣称历史日志已脱敏。
- 不处理本轮未确认的密钥存储/配置同步和未折算外币统计策略，也不进行大规模架构重构。
