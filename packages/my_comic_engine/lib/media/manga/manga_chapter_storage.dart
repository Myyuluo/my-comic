/// 在线漫画章 key 的摘要工具（互联协议用）。
///
/// Ticket 12 起磁盘布局由 Download library 负责（`downloads/{source}/{manga}/
/// {chapter}/` + `manga_chapter_dirs` 映射），旧的 `<my_comic_books>/<bookKey>/
/// chapters/<digest>/` 哈希布局与判据全部删除。这里只保留互联端点仍在用的
/// digest 形状：路径段是 `sha256(chapterKey)[:24]`，由章 key 现算，**不再当磁盘
/// 目录名**（磁盘目录名由映射给出）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 章 key 的摘要：`sha256(chapterKey)` 十六进制前 24 位。
///
/// 章 key 是源给的 URL / 路径，长度和字符集都不可控，不能直接进 URL 路径段。
String mangaChapterDigest(String chapterKey) =>
    sha256.convert(utf8.encode(chapterKey)).toString().substring(0, 24);

/// [value] 是否形如 [mangaChapterDigest] 的输出（24 位小写十六进制）。
///
/// 互联页图端点把 digest 当路径段收，进目录前先按此判形，杜绝穿越。
bool isMangaChapterDigest(String value) =>
    RegExp(r'^[0-9a-f]{24}$').hasMatch(value);
