import 'package:args/args.dart';
import 'package:my_comic_cli/my_comic_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

CtlCommandGroup _group(String name) =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == name);

CtlCommandSpec _spec(String name, {String group = 'library'}) =>
    _group(group).find(name) ?? (throw StateError('$group $name'));

/// 与 CLI 主循环同样装配解析器（`--help` + 命令自己的 option）后 build。
CtlRequestSpec _build(
  String name,
  List<String> args, {
  String group = 'library',
}) {
  final CtlCommandSpec spec = _spec(name, group: group);
  final ArgParser parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false);
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

void main() {
  test('命令组与子命令齐全', () {
    expect(kCtlCommandGroups.map((CtlCommandGroup g) => g.name), <String>[
      'library',
      'tag',
      'bookmark',
      'favorite',
    ]);
    expect(
      _group('library').commands.map((CtlCommandSpec s) => s.name),
      <String>[
        'ls',
        'get',
        'rm',
        'import',
        'open',
        'history',
        'sources',
        'scan',
        'source-add',
        'source-rename',
        'source-rm',
        'rename',
        'cover',
        'complete',
        'reset',
      ],
    );
  });

  test('全部请求都落在 /api/admin/library/ 下', () {
    final List<CtlRequestSpec> requests = <CtlRequestSpec>[
      _build('ls', const <String>[]),
      _build('get', const <String>['book:x']),
      _build('rm', const <String>['book:x', '--yes']),
      _build('import', const <String>['/a.epub']),
      _build('open', const <String>['book:x']),
      _build('history', const <String>[]),
      _build('sources', const <String>[]),
      _build('scan', const <String>[]),
    ];
    for (final CtlRequestSpec request in requests) {
      expect(request.path, startsWith('/api/admin/library/'));
    }
  });

  group('ls', () {
    test('无参数：GET items、空 query', () {
      final CtlRequestSpec r = _build('ls', const <String>[]);
      expect(r.method, 'GET');
      expect(r.path, '/api/admin/library/items');
      expect(r.query, isEmpty);
    });

    test('--kind / --search / --limit 进 query；kind 规整成小写', () {
      final CtlRequestSpec r = _build('ls', const <String>[
        '--kind',
        'Manga',
        '--search',
        '猫',
        '--limit',
        '5',
      ]);
      expect(r.query, <String, String>{
        'kind': 'manga',
        'search': '猫',
        'limit': '5',
      });
    });

    test('位置参数当搜索词并拼起来', () {
      final CtlRequestSpec r = _build('ls', const <String>['吾輩は', '猫']);
      expect(r.query, <String, String>{'search': '吾輩は 猫'});
    });

    test('未知 kind / 非法 limit → 用法错误', () {
      expect(
        () => _build('ls', const <String>['--kind', 'comic']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('ls', const <String>['--limit', '0']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('ls', const <String>['--limit', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('表格渲染带截断与隐藏模块提示', () {
      final String text = _spec('ls').render!(<String, Object?>{
        'total': 3,
        'items': <Object?>[
          <String, Object?>{
            'key': 'book:猫',
            'kind': 'book',
            'progress': '37%',
            'title': '猫',
          },
        ],
        'hiddenKinds': <String>['game'],
      });
      expect(text, contains('book:猫'));
      expect(text, contains('37%'));
      expect(text, contains('共 3 条'));
      expect(text, contains('game'));
    });
  });

  group('get', () {
    test('键整体编码成一段路径（id 里的 / 不拆段）', () {
      final CtlRequestSpec r = _build('get', const <String>[
        'video:video/ext/ab c',
      ]);
      expect(r.method, 'GET');
      expect(r.path, '/api/admin/library/items/video%3Avideo%2Fext%2Fab%20c');
      expect(
        Uri.parse('http://h${r.path}').pathSegments.last,
        'video:video/ext/ab c',
      );
    });

    test('缺 key → 用法错误', () {
      expect(
        () => _build('get', const <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('rm', () {
    test('没有 --yes → 用法错误', () {
      expect(
        () => _build('rm', const <String>['book:x']),
        throwsA(
          isA<CtlUsageError>().having(
            (CtlUsageError e) => e.message,
            'message',
            contains('--yes'),
          ),
        ),
      );
    });

    test('缺 key → 用法错误', () {
      expect(
        () => _build('rm', const <String>['--yes']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('--yes：DELETE + body 带 confirm 与三个选项', () {
      final CtlRequestSpec r = _build('rm', const <String>[
        'srt:srtbook_1',
        '--yes',
        '--everywhere',
        '--delete-files',
      ]);
      expect(r.method, 'DELETE');
      expect(r.path, '/api/admin/library/items/srt%3Asrtbook_1');
      expect(r.body, <String, Object?>{
        'confirm': true,
        'everywhere': true,
        'deleteFiles': true,
        'deleteStatistics': false,
      });
    });
  });

  group('import', () {
    test('相对路径在 CLI 侧转绝对路径；缺省 duplicate=skip', () {
      final CtlRequestSpec r = _build('import', const <String>[
        'a.epub',
        'dir/b.cbz',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/import');
      expect(r.body, <String, Object?>{
        'paths': <String>[
          p.normalize(p.absolute('a.epub')),
          p.normalize(p.absolute('dir/b.cbz')),
        ],
        'duplicate': 'skip',
      });
    });

    test('--kind / --duplicate 透传', () {
      final CtlRequestSpec r = _build('import', const <String>[
        '/x/book.epub',
        '/x/book.srt',
        '/x/01.mp3',
        '--kind',
        'manga',
        '--duplicate',
        'suffix',
      ]);
      expect(r.body!['kind'], 'manga');
      expect(r.body!['duplicate'], 'suffix');
      expect(r.body!['paths'], hasLength(3));
    });

    test('没有路径 → 用法错误；非法 kind → 解析失败', () {
      expect(
        () => _build('import', const <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('import', const <String>['/a', '--kind', 'pdf']),
        throwsA(isA<FormatException>()),
      );
    });

    test('渲染逐条结果', () {
      final String text = _spec('import').render!(<String, Object?>{
        'ok': false,
        'results': <Object?>[
          <String, Object?>{
            'path': '/a.epub',
            'status': 'imported',
            'keys': <String>['book:a'],
          },
          <String, Object?>{
            'path': '/b.mkv',
            'status': 'unsupported',
            'message': '视频文件请用 open',
          },
        ],
      });
      expect(text, contains('[已导入] /a.epub → book:a'));
      expect(text, contains('[不支持] /b.mkv'));
      expect(text, contains('视频文件请用 open'));
    });
  });

  group('open', () {
    test('POST …/open，--at 进 body', () {
      final CtlRequestSpec r = _build('open', const <String>[
        'video:v1',
        '--at',
        '1:30',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/items/video%3Av1/open');
      expect(r.body, <String, Object?>{'at': '1:30'});
    });

    test('不给 --at 时 body 为空对象', () {
      final CtlRequestSpec r = _build('open', const <String>['book:x']);
      expect(r.body, isEmpty);
    });

    test('缺 key → 用法错误', () {
      expect(
        () => _build('open', const <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('history', () {
    test('缺省不带 limit；-n 透传；非法值报错', () {
      expect(_build('history', const <String>[]).query, isEmpty);
      final CtlRequestSpec r = _build('history', const <String>['-n', '5']);
      expect(r.path, '/api/admin/library/history');
      expect(r.query, <String, String>{'limit': '5'});
      expect(
        () => _build('history', const <String>['-n', '-1']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('sources / scan', () {
    test('sources --kind 进 query', () {
      final CtlRequestSpec r = _build('sources', const <String>[
        '--kind',
        'manga',
      ]);
      expect(r.method, 'GET');
      expect(r.path, '/api/admin/library/sources');
      expect(r.query, <String, String>{'kind': 'manga'});
    });

    test('scan --kind / --source 进 body', () {
      final CtlRequestSpec r = _build('scan', const <String>[
        '--kind',
        'manga',
        '--source',
        '3',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/scan');
      expect(r.body, <String, Object?>{'kind': 'manga', 'source': 3});
    });

    test('scan --source 非整数 → 用法错误', () {
      expect(
        () => _build('scan', const <String>['--source', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('scan 渲染带错误', () {
      final String text = _spec('scan').render!(<String, Object?>{
        'results': <Object?>[
          <String, Object?>{
            'id': 1,
            'label': '动画',
            'discovered': 10,
            'imported': 2,
            'error': '目录不存在',
          },
        ],
      });
      expect(text, contains('#1 动画：发现 10 个，入库 2 个'));
      expect(text, contains('目录不存在'));
    });
  });
  test('新增命令组的请求同样落在 /api/admin/library/ 下', () {
    final List<CtlRequestSpec> requests = <CtlRequestSpec>[
      _build('source-add', const <String>['/d', '--kind', 'manga']),
      _build('source-rename', const <String>['3', '新名']),
      _build('source-rm', const <String>['3', '--yes']),
      _build('rename', const <String>['book:x', '新书名']),
      _build('cover', const <String>['book:x', '/a.png']),
      _build('complete', const <String>['book:x']),
      _build('reset', const <String>['book:x', '--yes']),
      _build('ls', const <String>[], group: 'tag'),
      _build('ls', const <String>['book:x'], group: 'bookmark'),
      _build('ls', const <String>[], group: 'favorite'),
    ];
    for (final CtlRequestSpec request in requests) {
      expect(request.path, startsWith('/api/admin/library/'));
    }
  });

  group('open 位置参数', () {
    test('--chapter / --progress / --page 进 body', () {
      final CtlRequestSpec r = _build('open', const <String>[
        'book:x',
        '--chapter',
        '3',
        '--progress',
        '40',
      ]);
      expect(r.body, <String, Object?>{'chapter': 3, 'progress': 40.0});
      expect(
        _build('open', const <String>['book:m', '--page', '12']).body,
        <String, Object?>{'page': 12},
      );
    });

    test('从 0 数 / 非数字 → 用法错误', () {
      expect(
        () => _build('open', const <String>['book:x', '--chapter', '0']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('open', const <String>['book:x', '--page', '0']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('open', const <String>['book:x', '--progress', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('library 来源 / 改名 / 封面 / 读完 / 重置', () {
    test('source-add 必须给 --kind，路径转绝对', () {
      final CtlRequestSpec r = _build('source-add', const <String>[
        'anime',
        '--kind',
        'manga',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/sources');
      expect(r.body, <String, Object?>{
        'path': p.normalize(p.absolute('anime')),
        'kind': 'manga',
      });
      expect(
        () => _build('source-add', const <String>['/d']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('source-rename / source-rm', () {
      final CtlRequestSpec rename = _build('source-rename', const <String>[
        '4',
        '新',
        '名字',
      ]);
      expect(rename.method, 'PUT');
      expect(rename.path, '/api/admin/library/sources/4');
      expect(rename.body, <String, Object?>{'label': '新 名字'});
      expect(
        () => _build('source-rm', const <String>['4']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec rm = _build('source-rm', const <String>[
        '4',
        '--yes',
        '--migrate-to',
        '7',
      ]);
      expect(rm.method, 'DELETE');
      expect(rm.body, <String, Object?>{'confirm': true, 'migrateTo': 7});
      expect(
        () => _build('source-rm', const <String>['x', '--yes']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rename：新名字拼起来；--reset 清除改名且不带名字', () {
      final CtlRequestSpec r = _build('rename', const <String>[
        'srt:u1',
        '銀河',
        '鉄道',
      ]);
      expect(r.method, 'PUT');
      expect(r.path, '/api/admin/library/items/srt%3Au1/title');
      expect(r.body, <String, Object?>{'title': '銀河 鉄道'});
      expect(
        _build('rename', const <String>['book:x', '--reset']).body,
        <String, Object?>{'reset': true},
      );
      expect(
        () => _build('rename', const <String>['book:x', '--reset', 'y']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('rename', const <String>['book:x']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('cover：URL 原样、本地路径转绝对、--reset', () {
      expect(
        _build('cover', const <String>[
          'video:v',
          'https://example.com/a.jpg',
        ]).body,
        <String, Object?>{'url': 'https://example.com/a.jpg'},
      );
      final CtlRequestSpec local = _build('cover', const <String>[
        'book:x',
        'c.png',
      ]);
      expect(local.path, '/api/admin/library/items/book%3Ax/cover');
      expect(local.body, <String, Object?>{
        'path': p.normalize(p.absolute('c.png')),
      });
      expect(
        _build('cover', const <String>['book:x', '--reset']).body,
        <String, Object?>{'reset': true},
      );
    });

    test('complete / --undo；reset 需 --yes 并带 stats', () {
      expect(
        _build('complete', const <String>['book:x']).body,
        <String, Object?>{'completed': true},
      );
      expect(
        _build('complete', const <String>['book:x', '--undo']).body,
        <String, Object?>{'completed': false},
      );
      expect(
        () => _build('reset', const <String>['book:x']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec reset = _build('reset', const <String>[
        'video:v',
        '--yes',
        '--stats',
        'last',
      ]);
      expect(reset.method, 'POST');
      expect(reset.path, '/api/admin/library/items/video%3Av/reset');
      expect(reset.body, <String, Object?>{'confirm': true, 'stats': 'last'});
    });
  });

  group('tag', () {
    test('ls 不带键列全部，带键列条目的标签', () {
      expect(
        _build('ls', const <String>[], group: 'tag').path,
        '/api/admin/library/tags',
      );
      expect(
        _build('ls', const <String>['book:x'], group: 'tag').path,
        '/api/admin/library/items/book%3Ax/tags',
      );
    });

    test('create / edit / rm', () {
      final CtlRequestSpec create = _build('create', const <String>[
        '名作',
        '--color',
        '#FF0000',
      ], group: 'tag');
      expect(create.body, <String, Object?>{'name': '名作', 'color': '#FF0000'});
      expect(
        () => _build('edit', const <String>['3'], group: 'tag'),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec edit = _build('edit', const <String>[
        '3',
        '--name',
        '新',
      ], group: 'tag');
      expect(edit.method, 'PUT');
      expect(edit.path, '/api/admin/library/tags/3');
      expect(edit.body, <String, Object?>{'name': '新'});
      expect(
        () => _build('rm', const <String>['3'], group: 'tag'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('add / remove：条目键统一走 items 路径', () {
      final CtlRequestSpec item = _build('add', const <String>[
        'video:v',
        '名作',
        '再看',
        '--create',
      ], group: 'tag');
      expect(item.method, 'POST');
      expect(item.path, '/api/admin/library/items/video%3Av/tags');
      expect(item.body, <String, Object?>{
        'tags': <String>['名作', '再看'],
        'create': true,
      });
      final CtlRequestSpec remove = _build('remove', const <String>[
        'book:b',
        '名作',
      ], group: 'tag');
      expect(remove.method, 'DELETE');
      expect(remove.path, '/api/admin/library/items/book%3Ab/tags');
    });
  });

  group('bookmark', () {
    test('add：EPUB 用 --chapter，PDF 用 --page，二选一', () {
      final CtlRequestSpec epub = _build('add', const <String>[
        'book:x',
        '--chapter',
        '2',
        '--progress',
        '50',
        '--label',
        '名场面',
      ], group: 'bookmark');
      expect(epub.path, '/api/admin/library/items/book%3Ax/bookmarks');
      expect(epub.body, <String, Object?>{
        'chapter': 2,
        'progress': 50.0,
        'label': '名场面',
      });
      expect(
        _build('add', const <String>[
          'book:p',
          '--page',
          '7',
        ], group: 'bookmark').body,
        <String, Object?>{'page': 7},
      );
      expect(
        () => _build('add', const <String>['book:x'], group: 'bookmark'),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => _build('add', const <String>[
          'book:x',
          '--chapter',
          '1',
          '--page',
          '1',
        ], group: 'bookmark'),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('rm 走 DELETE bookmarks/<id>；渲染位置', () {
      final CtlRequestSpec rm = _build('rm', const <String>[
        '12',
      ], group: 'bookmark');
      expect(rm.method, 'DELETE');
      expect(rm.path, '/api/admin/library/bookmarks/12');
      final String text = _spec('ls', group: 'bookmark').render!(
        <String, Object?>{
          'bookmarks': <Object?>[
            <String, Object?>{
              'id': 1,
              'chapter': 3,
              'progress': 25,
              'label': 'Ch.3',
            },
            <String, Object?>{'id': 2, 'page': 9, 'label': 'P.9'},
          ],
        },
      );
      expect(text, contains('#1 第 3 章 25%'));
      expect(text, contains('#2 P.9'));
    });
  });

  group('favorite', () {
    test('ls 按条目筛 + limit；rm 编码 id；clear 需 --yes', () {
      expect(
        _build('ls', const <String>[
          'book:x',
          '-n',
          '3',
        ], group: 'favorite').query,
        <String, String>{'key': 'book:x', 'limit': '3'},
      );
      expect(
        _build('rm', const <String>['hl_1_2'], group: 'favorite').path,
        '/api/admin/library/favorites/hl_1_2',
      );
      expect(
        () => _build('clear', const <String>[], group: 'favorite'),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        _build('clear', const <String>['--yes'], group: 'favorite').body,
        <String, Object?>{'confirm': true},
      );
    });

    test('export：输出路径转绝对，格式 / 条目 / 去重透传', () {
      final CtlRequestSpec r = _build('export', const <String>[
        'out.csv',
        '--format',
        'csv',
        '--item',
        'video:v',
        '--dedupe',
      ], group: 'favorite');
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/library/favorites/export');
      expect(r.body, <String, Object?>{
        'path': p.normalize(p.absolute('out.csv')),
        'format': 'csv',
        'key': 'video:v',
        'dedupe': true,
      });
    });
  });


}
