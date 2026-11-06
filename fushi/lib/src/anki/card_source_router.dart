import 'dart:async';
import 'dart:io';
import 'package:fushi/src/media/media_item_factory.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';


import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';

import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// Finds the local book/manga row a card link points at. The link's `uid` is
/// minted per device at import (sync / interconnect re-import a book and get a
/// fresh one), so a card mined on another device only matches here through the
/// cross-device `bookKey`. `uid` goes first: it survives a local rename, which
/// changes the title-derived `bookKey`.
Future<EpubBookRow?> resolveCardSourceBook(
  FushiDatabase db,
  CardSourceLink link,
) async {
  final EpubBookRow? byUid = await db.getEpubBookByUid(link.uid);
  if (byUid != null) return byUid;
  final String? bookKey = link.bookKey;
  return bookKey == null ? null : db.getEpubBook(bookKey);
}

/// 在互联 host 的视频清单里找卡片链接指向的那条。远端视频的 id 就是 host 库里的
/// `bookUid`，与卡片链接的 `uid` 同一个键；找不到返回 null。
///
/// Resolve a portable locator through the current library. URLs never supply
/// paths, remote credentials, or arbitrary routes to the navigation layer.
Future<void> openCardSource({
  required WidgetRef ref,
  required CardSourceLink link,
}) => ExternalMediaNavigation.instance.navigate(
  () => _openCardSource(ref: ref, link: link),
);

Future<void> _openCardSource({
  required WidgetRef ref,
  required CardSourceLink link,
}) async {
  final AppModel app = ref.read(appProvider);
  final NavigatorState? navigator = app.navigatorKey.currentState;
  if (navigator == null || app.isMigrationReadonly) return;
  if (link.kind == CardSourceKind.video) {
    FushiToast.show(msg: t.card_source_review_media_missing);
    return;
  }
  final EpubBookRow? book = await resolveCardSourceBook(app.database, link);
  if (book == null) {
    FushiToast.show(msg: t.card_source_review_media_missing);
    return;
  }
  if (book != null) {
    final BookFormat format = BookFormat.parseOrEpub(book.format);
    if ((link.kind == CardSourceKind.manga && format != BookFormat.manga) ||
        (link.kind == CardSourceKind.book && format != BookFormat.epub)) {
      FushiToast.show(msg: t.card_source_review_invalid);
      return;
    }
    if (link.kind == CardSourceKind.book &&
        (link.chapterIndex == null ||
            link.chapterIndex! >= book.chapterCount)) {
      FushiToast.show(msg: t.card_source_review_invalid);
      return;
    }
  }
  final MediaItem? previousItem = app.currentMediaItem;
  final MediaSource? previousSource = app.currentMediaSource;
  final Future<void> Function()? previousReturn =
      ExternalMediaNavigation.instance.returnToReading;
  if (!await ExternalMediaNavigation.instance.closeActive()) {
    FushiToast.show(msg: t.card_source_review_failed);
    return;
  }
  // A background audiobook must finish its normal final write before the
  // review installs temporary persistence callbacks on a new controller.
  await app.audiobookSession.stop();
  if (!navigator.mounted) return;

  final BaseAnkiRepository configured = ref.read(ankiRepositoryProvider);
  // provider 恒返回装饰器链（待发队列 / 自动重排），`configured is
  // AnkiMobileRepository` 永远不成立——必须拆装饰器判「卡落在哪」。
  final BaseAnkiRepository repository =
      Platform.isIOS && minesOnLocalAnkiMobile(configured)
      ? RemoteMiningAnkiRepository(
          local: configured,
          client: app.createRemoteMiningClient(),
        )
      : configured;
  final SourceReviewSession session = SourceReviewSession(
    link: link,
    repository: repository,
    draftStore: SourceReviewDraftStore(
      Directory('${app.appDirectory.path}/card_source_drafts'),
    ),
    onReturnToReading:
        previousReturn ??
        () => ExternalMediaNavigation.instance.navigate(() async {
          if (!await ExternalMediaNavigation.instance.closeActive()) return;
          await app.audiobookSession.stop();
          if (!navigator.mounted) return;
          if (previousItem != null && previousSource != null) {
            await app.openMedia(
              ref: ref,
              mediaSource: previousSource,
              item: previousItem,
              waitUntilClosed: false,
            );
          }
          await WidgetsBinding.instance.endOfFrame;
        }),
  );
  final EpubBookRow row = book!;
  final BookFormat format = BookFormat.parseOrEpub(row.format);
  final MediaItem item = buildCollectionReaderMediaItem(
    bookKey: row.bookKey,
    title: row.title,
    format: format,
  );
  final Bookmark bookmark = Bookmark(
    sectionIndex: link.chapterIndex ?? 0,
    normCharOffset: 0,
    charAnchor: link.charOffset,
    charAnchorLength: link.charLength,
    preserveSavedPosition: true,
    label: '',
    createdAt: DateTime.now(),
  );
  await app.openMedia(
    ref: ref,
    mediaSource: item.getMediaSource(appModel: app),
    item: item,
    recordHistory: false,
    waitUntilClosed: false,
    launchPageBuilder: () => SourceReviewScope(
      session: session,
      child: FushiAppUiScaleNeutralizer(
        child: link.kind == CardSourceKind.manga
            ? MangaFushiPage(
                item: item,
                bookKey: row.bookKey,
                sourceReview: link,
              )
            : LyricsThemeHost(
                child: ReaderFushiPage(
                  item: item,
                  bookKey: row.bookKey,
                  initialBookmarkJump: bookmark,
                ),
              ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
}
