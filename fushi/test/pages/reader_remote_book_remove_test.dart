import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/hidden_remote_books.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 反馈 nvlhtczbro：云端（互联）书从书架移除时的「仅从本机移除」清单。
///
/// 远端书混排 / 移除 / 找回 UI 随 my-comic v1 移除同步互联模块一并下线；
/// 这里只保留仍随旧备份解析的偏好编码守卫。
void main() {
  test('「仅从本机移除」清单是设备本地偏好：不随备份 / 同步带到别的设备', () {
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains('hidden_remote_books'),
      reason: '「仅从本机」漂到另一台设备会让那边的同一份远端书也被隐藏',
    );
  });

  test('旧版只存键串的清单读进来不丢', () {
    final List<HiddenRemoteBook> books = decodeHiddenRemoteBooks(
      '["interconnect/Remote%20Book","cloud:webDav/a%2Fb"]',
    );
    expect(
      books.map((HiddenRemoteBook h) => (h.sourceId, h.remoteId, h.sourceHost)),
      <(String, String, String?)>[
        ('interconnect', 'Remote Book', null),
        ('cloud:webDav', 'a/b', null),
      ],
    );
    expect(
      isRemoteBookHidden(
        books,
        sourceId: 'interconnect',
        sourceHost: 'any-host',
        remoteId: 'Remote Book',
      ),
      isTrue,
      reason: '旧条目不分对端，保持升级前行为',
    );
  });
}
