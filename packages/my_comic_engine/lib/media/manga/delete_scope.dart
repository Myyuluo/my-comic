/// 用户删除书架条目时选择的传播范围（源设备弹窗采集）。
///
/// 原住在 `sync/deletion_propagation.dart`（云同步/互联域）。同步传输本身已随
/// my-comic 独立化删除，但删除确认弹窗与书架删除 API 仍保留这两个取值以维持
/// 旧调用面与失败语义。本机 `sync_deletion_tombstones` 记账仍按旧语义写入
/// （备份合并防复活依赖它）；`syncEverywhere` 不再向任何远端发布墓碑。
enum DeleteScope { keepLocalOnly, syncEverywhere }
