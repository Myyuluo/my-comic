export 'i18n/strings.g.dart';

export 'src/utils/my_comic_localisations.dart';

export 'src/utils/components/cache_image_provider.dart';
export 'src/utils/components/copy_feedback.dart';
export 'src/utils/components/my_comic_gamepad_keyboard.dart';
export 'src/utils/components/my_comic_icon_button.dart';
export 'src/utils/components/my_comic_floating_page_chrome.dart';
export 'src/utils/components/my_comic_toolbar.dart';
export 'src/utils/components/my_comic_reorderable_column.dart';
export 'src/utils/components/my_comic_reorder_drag_listener.dart';
export 'src/utils/components/my_comic_divider.dart';
export 'src/utils/components/my_comic_scrollbar.dart';
export 'src/utils/components/my_comic_dropdown.dart';
export 'src/utils/components/my_comic_option_selection_page.dart';
export 'src/utils/components/my_comic_marquee.dart';
export 'src/utils/components/my_comic_tag.dart';
export 'src/utils/components/cover_badge.dart';
export 'src/utils/components/my_comic_destructive_confirm_dialog.dart';
export 'src/utils/components/my_comic_placeholder_message.dart';
export 'src/utils/components/my_comic_loading_view.dart';
export 'src/utils/components/my_comic_inline_notice.dart';
export 'src/utils/components/my_comic_neutral_decor.dart';
export 'src/utils/components/my_comic_section_title.dart';
export 'src/utils/components/shelf_card_widgets.dart';
export 'src/utils/components/my_comic_text_selection_controls.dart';
export 'src/utils/components/content_language_picker.dart';
export 'src/utils/components/my_comic_list_tile.dart';
export 'src/utils/components/my_comic_focusable.dart';
export 'src/utils/components/my_comic_hover_lift.dart';
export 'src/utils/components/my_comic_focus_ring.dart';

export 'src/utils/components/my_comic_design_tokens.dart';
export 'src/utils/components/my_comic_motion_tokens.dart';
export 'src/utils/components/my_comic_m3e_overlays.dart' hide MyComicSpringCurve;
export 'src/utils/components/my_comic_typography.dart';
export 'src/utils/components/my_comic_glass_surface.dart';
export 'src/utils/components/glass/my_comic_glass_controls.dart';
export 'src/utils/components/my_comic_material_components.dart';
export 'src/utils/components/library_section_tabs.dart';
export 'src/utils/components/section_swipe_navigator.dart';
export 'src/utils/components/settings_shared.dart';
export 'src/utils/app_ui_scale.dart';
export 'src/utils/popup_theme_css.dart';

export 'src/utils/misc/my_comic_byte_format.dart';
export 'src/utils/misc/my_comic_color.dart';
export 'package:my_comic_engine/utils/misc/my_comic_time_format.dart';
export 'package:my_comic_engine/utils/misc/safe_file_name.dart';
export 'src/models/my_comic_text_selection.dart';
export 'src/utils/misc/volume_key_channel.dart';
export 'src/utils/misc/error_log_service.dart';
export 'src/utils/misc/render_backend_service.dart';
export 'src/utils/misc/debug_log_service.dart';
export 'src/utils/misc/show_app_dialog.dart';
export 'src/utils/misc/update_checker.dart';
// 全应用出站代理解析层。原先是 update_checker 的 part（随上一行一起被导出），BUG-1348
// 把它提成独立库供同步层复用，故这里显式补一条 export，消费方 import 路径零变化。
export 'package:my_comic_engine/utils/net/app_proxy.dart';
// BUG-1498：公网出站的单一装配点（同步工厂），以及两个下游包的接线文件。
export 'package:my_comic_engine/utils/net/app_http.dart';
export 'src/utils/misc/update_check_cache.dart';
export 'src/utils/misc/my_comic_toast.dart';
export 'src/utils/misc/webview_asset_url.dart';
export 'src/utils/misc/platform_utils.dart';
export 'src/utils/misc/gallery_image_picker.dart';
// 官网入口（侧栏左上角 app 图标 + 设置 · 通用 · 官网共用同一个 URL）。
export 'src/utils/misc/official_links.dart';

export 'src/utils/adaptive/my_comic_adaptive.dart';
