import { SearchingPageParams } from "../viewmodel/SearchViewModel";
import { PixivImageComponent } from "../components/PixivImage";
import { PixState, _PixState } from "../entryability/AppState";
import { GridColumnsTemplate } from "../common/utils/breakpoint/BreakPoint";
import { IllustDetailViewModel, recordIllustViewHistory } from "../viewmodel/IllustDetailViewModel";
import { SnapShotUtils } from "../common/utils/SnapShotUtils";
import { PixivIllust, PixivImage, PixivTag } from "../services/PixivTypes";
import { LengthMetrics, curves, window } from "@kit.ArkUI";
import UIConstants from "../common/constants/UIConstants";
import { homeViewModel } from "../viewmodel/HomeViewModel";
import { DetailPageParams, IIllustSwiperProvider } from "../common/entity/DetailEntity";
import { UserItem } from "../components/UserItem";
import { PixivImageViewer } from "../components/ImageViewer";
import { UgoiraPlayer } from "../components/UgoiraPlayer";
import { NaviContainer } from "../components/NaviContainer";
import { appSettings } from "../common/entity/SettingsModel";
import { hdsEffect } from "@kit.UIDesignKit";
import { ColorUtils } from "../common/utils/ColorUtils";
import { LongTakeAnimationProperties } from "../common/utils/customtransition/LongTakeAnimationProperties";
import { CustomTransition } from "../common/utils/customtransition/CustomNavigationUtils";
import { CardUtil } from "../common/utils/CardUtil";
import { createLogger } from "../common/utils/Logger";
import { CommentPanel } from "./CommentPanel";
import { toastUtil } from "../common/utils/ToastUtils";
import { tagCollectionVM } from "../viewmodel/TagCollectionVM";
import { EmptyStateView } from "../components/CommonWidgets";
import { SymbolGlyphModifier } from "@kit.ArkUI";
import { ShareUtil } from "../common/utils/ShareUtil";

const logger = createLogger('IllustDetail')


@Builder
export function IllustDetailBuilder(name: string, param: Object) {
  IllustDetail()
}

// 外层：负责 Swiper 容器与转场动画
@ComponentV2
struct IllustDetail {

  @Local illustTitle: string = ''
  @Local showLargeImage: boolean = false
  // 全屏看图器处于放大态：禁用外层 Swiper，避免横滑穿透导致切作品
  @Local viewerZoomed: boolean = false
  @Local currentSwiperIndex: number = 0
  // Swiper 数据源快照：provider 的 illustIds 是"每次访问都新建数组"的 getter 且不被状态管理观察，
  // 直接绑定会让 Repeat 在每次重渲染时拿到新引用而全量重同步，配合单向 index 造成概率性跳回进入时的作品。
  // 改为组件内稳定快照，仅在 loadMore 有新增时去重刷新。
  @Local swiperIds: number[] = []

  private pageStack: NavPathStack = new NavPathStack()
  private swiperProvider: IIllustSwiperProvider | undefined = undefined
  private initialId: number = 0
  private initialSwiperIndex: number = 0
  // 子页上报过的标题缓存：上报时若不是当前页则先缓存，切到该页时再套用
  private titleCache: Map<number, string> = new Map()
  // 子页上报过的详情缓存（含 Swiper 预载页）：分享按钮按当前页 id 取用
  private detailCache: Map<number, PixivIllust> = new Map()
  private sharedId: string = ''
  private longTakeAnimationProperties: LongTakeAnimationProperties = new LongTakeAnimationProperties();
  // 看图沉浸前保存的系统栏属性，退出时原样恢复（兼容深浅色模式）
  private savedBarProps: window.SystemBarProperties | undefined = undefined

  /** 看图即沉浸：隐藏页面标题栏，系统栏转透明底白字；关闭时恢复 */
  @Monitor('showLargeImage')
  onShowLargeImageChange(): void {
    const win: window.Window | undefined = _PixState.window
    if (!win) return
    try {
      if (this.showLargeImage) {
        this.savedBarProps = win.getWindowSystemBarProperties()
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#FFFFFF'
        })
      } else if (this.savedBarProps) {
        win.setWindowSystemBarProperties(this.savedBarProps)
        this.savedBarProps = undefined
      }
    } catch (err) {
      logger.warn(` ImmersiveViewer`, `Failed to switch system bar properties: ${err}`)
    }
  }

  build() {
    NaviContainer({
      title: this.illustTitle,
      // 看图即沉浸：隐藏页面标题栏，让全屏查看器铺满窗口
      hideTitleBar: this.showLargeImage,
      buttons: this.detailButtons(),
      content: () => { this.Content() },
      onReady: (ctx) => {
        this.pageStack = ctx.pathStack
        this.handleTransitionReady(ctx)
      },
      onBackPressed: () => {
        if (this.showLargeImage) {
          this.showLargeImage = false
          this.viewerZoomed = false
          return true
        }
        return false
      },
      onNaviDisAppear: () => {
        homeViewModel.restoreIllustVisibility();
        SnapShotUtils.clear();
      }
    })
  }

  /** 顶栏右上角：分享按钮（按「分享文本格式」模板渲染文本分享当前作品） */
  private detailButtons(): NavigationMenuItem[] {
    return [{
      value: '分享',
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.share')),
      action: () => {
        const detail = this.detailCache.get(this.currentDetailId());
        if (detail) {
          ShareUtil.shareIllustText(detail);
        } else {
          // 详情未就绪时兜底分享裸链接
          ShareUtil.shareText(`链接：https://www.pixiv.net/artworks/${this.currentDetailId()}`);
        }
      }
    }];
  }

  // 处理转场动画初始化
  private handleTransitionReady(ctx: NavDestinationContext) {
    const params = ctx?.pathInfo?.param as DetailPageParams;
    if (!params) return;

    this.initialId = params.id;
    this.swiperProvider = params.swiperProvider;
    // 初始页即视为浏览过，此刻记录历史（历史不再由 loadIllustDetail 内部写入，预加载页不能污染历史）
    recordIllustViewHistory(this.initialId);

    if (this.swiperProvider) {
      this.swiperIds = this.dedupeIds(this.swiperProvider.illustIds);
      // swiperIndex 由列表页按首次出现的下标传入，校验失效时回退 indexOf
      let idx = params.swiperIndex ?? -1;
      if (idx < 0 || this.swiperIds[idx] !== params.id) {
        idx = this.swiperIds.indexOf(params.id);
      }
      this.initialSwiperIndex = Math.max(idx, 0);
      this.currentSwiperIndex = this.initialSwiperIndex;
    }
    // 列表项自带标题时先兜底显示，详情加载完成后再由子页上报覆盖
    if (params.illust?.title) {
      this.illustTitle = params.illust.title;
    }

    const fromId = params.fromId as string;
    const pageId = ctx.navDestinationId;
    if (!pageId || !fromId) {
      this.longTakeAnimationProperties.setFinalStatus();
      return;
    }
    this.sharedId = CardUtil.getPostPageImageId(fromId) || fromId;

    this.longTakeAnimationProperties.init(fromId, () => {
      homeViewModel.restoreIllustVisibility();
    });

    CustomTransition.getInstance().registerNavParam(pageId, 2000, (proxy: NavigationTransitionProxy) => {
      this.longTakeAnimationProperties.doAnimation(proxy);
    });
  }

  @Builder Content() {
    if (this.swiperProvider && appSettings.swiper_browsing) {
      // === Swiper 模式 ===
      Swiper() {
        Repeat<number>(this.swiperIds)
          .virtualScroll({ totalCount: this.swiperIds.length, reusable: false }) // 禁用复用，触发加载
          .key((id: number) => id.toString())
          .each((ri: RepeatItem<number>) => {
            IllustDetailContent({
              illustId: ri.item,
              sharedId: ri.item === this.initialId ? this.sharedId : '',
              pageStack: this.pageStack,
              showLargeImage: this.showLargeImage,
              onImageLarge: (show) => {
                this.showLargeImage = show
                if (!show) {
                  this.viewerZoomed = false
                }
              },
              onViewerZoom: (zoomed) => { this.viewerZoomed = zoomed },
              onTitle: (id: number, title: string) => { this.handleTitleReport(id, title) },
              onDetail: (id: number, detail: PixivIllust) => { this.detailCache.set(id, detail) }
            })
          })
      }
      // 双向绑定当前索引：即使数据源变化引发子项重同步，Swiper 也会回到用户所在页，而不是进入时的作品
      .index(this.currentSwiperIndex!!)
      .indicator(false)
      .loop(false)
      // 预创建左右相邻页：子页 aboutToAppear 提前拉取详情与图片，滑动切换时内容已就绪，
      // 不再出现滑动过程中等待"加载中"的卡顿；预载请求由 RequestGate 限流、LRU 缓存去重兜底
      .cachedCount(1, false)
      .disableSwipe(this.showLargeImage && this.viewerZoomed)
      .onChange((index: number) => {
        this.currentSwiperIndex = index;
        this.applyCurrentTitle();
        this.tryLoadMore(index);
        // 滑到该页才算"浏览过"，此时记录历史（详情已由预加载拉取，直接命中缓存）
        const id = this.swiperIds[index];
        if (id) {
          recordIllustViewHistory(id);
        }
      })
      .width('100%')
      .height('100%')
    } else {
      // === 单页模式 ===
      IllustDetailContent({
        illustId: this.initialId,
        sharedId: this.sharedId,
        pageStack: this.pageStack,
        showLargeImage: this.showLargeImage,
        onImageLarge: (show) => {
          this.showLargeImage = show
          if (!show) {
            this.viewerZoomed = false
          }
        },
        onTitle: (id: number, title: string) => { this.handleTitleReport(id, title) },
        onDetail: (id: number, detail: PixivIllust) => { this.detailCache.set(id, detail) }
      })
        .width('100%')
        .height('100%')
    }
  }

  // 触底预加载逻辑
  private tryLoadMore(index: number) {
    if (!this.swiperProvider || !this.swiperProvider.hasMore || this.swiperProvider.isLoading) return;
    // 滑到倒数第 2 张时，触发预加载；完成后同步去重快照（无新增则保持引用稳定，不触发 Repeat 重同步）
    if (index >= this.swiperIds.length - 2) {
      const provider = this.swiperProvider;
      provider.loadMore().then(() => {
        if (this.swiperProvider !== provider) return;
        const fresh = this.dedupeIds(provider.illustIds);
        if (fresh.length !== this.swiperIds.length) {
          this.swiperIds = fresh;
        }
      }).catch(() => {});
    }
  }

  /** 去重保序：provider 分页叠加可能产生重复 id，重复 key 会破坏 Repeat 子项对账与 Swiper 索引 */
  private dedupeIds(ids: number[]): number[] {
    const seen = new Set<number>()
    const result: number[] = []
    for (const id of ids) {
      if (!seen.has(id)) {
        seen.add(id)
        result.push(id)
      }
    }
    return result
  }

  /** 当前应展示标题的作品 id：Swiper 模式取当前页，单页模式取进入时的作品 */
  private currentDetailId(): number {
    if (this.swiperProvider) {
      const idx = this.currentSwiperIndex
      if (idx >= 0 && idx < this.swiperIds.length) {
        return this.swiperIds[idx]
      }
    }
    return this.initialId
  }

  /** 子页上报标题：不是当前页时先入缓存，等切到该页再套用，避免后台页覆盖当前标题 */
  private handleTitleReport(id: number, title: string) {
    this.titleCache.set(id, title)
    if (id === this.currentDetailId()) {
      this.illustTitle = title
    }
  }

  /** 切页后套用已缓存的目标页标题（目标页尚未加载完则保留旧标题，等其上报） */
  private applyCurrentTitle() {
    const cached = this.titleCache.get(this.currentDetailId())
    if (cached !== undefined) {
      this.illustTitle = cached
    }
  }
}

// 内层：负责单张插画的数据与 UI
@ComponentV2
struct IllustDetailContent {

  @Param illustId: number = 0
  @Param sharedId: string = ''
  @Param showLargeImage: boolean = false
  @Param pageStack: NavPathStack = new NavPathStack()

  @Local currentImageIndex: number = 0
  @Local showCommentPanel: boolean = false
  @Local iDV: IllustDetailViewModel = new IllustDetailViewModel()
  // 标签长按菜单（isShow 由各胶囊按 menuTagName 匹配，避免多个菜单同时弹出）
  @Local showTagMenu: boolean = false
  @Local menuTagName: string = ''

  @Event onImageLarge: (show: boolean) => void
  @Event onViewerZoom: (zoomed: boolean) => void
  @Event onTitle: (illustId: number, title: string) => void
  @Event onDetail: (illustId: number, detail: PixivIllust) => void

  async aboutToAppear(): Promise<void> {
    // 根据 ID 加载详情，完成后上报标题（外层判断是否为当前页再套用，不再依赖卡片可见性回调）
    await this.iDV.loadIllustDetail(this.illustId);
    const detail = this.iDV.detailData
    if (detail) {
      this.onTitle(this.illustId, detail.title)
      this.onDetail(this.illustId, detail)
    }
    this.iDV.loadRelated(this.illustId);
  }

  /** 当前作品命中的屏蔽词 */
  private blockedTagNames(): string[] {
    return tagCollectionVM.blockedNamesIn(this.iDV.detailData?.tags);
  }

  /** 动图播放器的宽高比（取作品原始宽高；无有效值时由预览图自适应撑起） */
  private ugoiraAspectRatio(): number | undefined {
    const detail = this.iDV.detailData;
    if (!detail || !detail.width || !detail.height || detail.width <= 0 || detail.height <= 0) {
      return undefined;
    }
    return detail.width / detail.height;
  }

  /** 标签长按菜单：收藏 / 屏蔽 */
  @Builder
  TagMenu(tag: PixivTag) {
    Menu() {
      MenuItem({
        content: tagCollectionVM.isFavorite(tag.name) ? '取消收藏' : '收藏关键词',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.star_circle')).fontColor(['#FF9500'])
      })
        .onClick(() => {
          // 选中即收起：必须先关菜单再改数据，否则数据刷新引发菜单收起-展开-收起的闪烁
          this.showTagMenu = false;
          if (tagCollectionVM.isFavorite(tag.name)) {
            tagCollectionVM.removeFavorite(tag.name);
          } else {
            tagCollectionVM.addFavorite(tag.name, tag.translated_name || '');
          }
        })
      MenuItem({
        content: tagCollectionVM.isBlocked(tag.name) ? '取消屏蔽' : '屏蔽关键词',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.exclamationmark_shield_fill'))
          .fontColor([$r('sys.color.font_secondary')])
      })
        .onClick(() => {
          this.showTagMenu = false;
          if (tagCollectionVM.isBlocked(tag.name)) {
            tagCollectionVM.removeBlocked(tag.name);
          } else {
            tagCollectionVM.addBlocked(tag.name, tag.translated_name || '');
          }
        })
    }
  }

  /** 详情未就绪时的占位：加载中 / 失败重试（失败不再静默空白） */
  @Builder
  DetailPlaceholder() {
    if (this.iDV.isDetailLoading) {
      Column({ space: 12 }) {
        LoadingProgress()
          .width(44)
          .height(44)
          .color(PixState.currentThemeColor)
        Text('加载中...')
          .fontSize(14)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      Column() {
        EmptyStateView({
          icon: $r('sys.symbol.exclamationmark_triangle'),
          message: '作品加载失败，请检查网络后重试',
          actionText: '重试',
          onAction: () => {
            this.iDV.loadIllustDetail(this.illustId)
            this.iDV.loadRelated(this.illustId)
          }
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    // 详情未加载成功：显示加载中或失败重试占位
    if (!this.iDV.detailData) {
      this.DetailPlaceholder()
    } else if (tagCollectionVM.hasBlockedTags(this.iDV.detailData.tags)) {
      // 屏蔽兜底：从列表过滤覆盖不到的入口（评论、用户页等）直接打开时，整页占位
      Column() {
        EmptyStateView({
          icon: $r('sys.symbol.exclamationmark_shield_fill'),
          message: `该作品包含已屏蔽的关键词：${this.blockedTagNames().join('、')}`,
          actionText: '取消屏蔽',
          onAction: () => {
            tagCollectionVM.removeBlockedNames(this.blockedTagNames());
          }
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      Stack({ alignContent: 8 - PixState.buttonPosition }) {
      Row() {
        List({ space: 10 }) {
          if (this.iDV.isUgoira) {
            // 动图：播放器替代静态图片列表（ugoira 恒为单图，不进全屏查看器）
            ListItem() {
              UgoiraPlayer({
                illustId: this.illustId,
                previewUrl: this.iDV.detailImageUrls[0] || this.iDV.imageList[0]?.medium || '',
                frameRatio: this.ugoiraAspectRatio()
              })
            }
          } else {
            ForEach(this.iDV.imageList, (illust: PixivImage, index: number) => {
              ListItem() {
                PixivImageComponent({
                  imageUrl: this.iDV.detailImageUrls[index] || illust.medium,
                  imageObjectFit: ImageFit.Auto,
                  imageBorder: { radius: 0 },
                })
                  .id(index === 0 ? this.sharedId : illust.medium)
              }
              .onClick(() => {
                this.currentImageIndex = index
                this.onImageLarge(true)
              })
            })
          }

          if (PixState.widthBp < 2 && this.iDV.detailData) {
            this.IntroContent()
          }
        }
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .contentEndOffset(PixState.bottomRectHeight == 0 ? PixState.PageMarginValue : PixState.bottomRectHeight)
        .padding(({ left: PixState.PageMarginValue, right: PixState.PageMarginValue }))
        .width(PixState.widthBp < 2 ? '100%' : PixState.windowWidth / 2)

        if (PixState.widthBp >= 2 && this.iDV.detailData) {
          List({ space: 10 }) {
            this.IntroContent()
          }
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .contentEndOffset(PixState.bottomRectHeight == 0 ? PixState.PageMarginValue : PixState.bottomRectHeight)
          .contentStartOffset(60 + PixState.topRectHeight)
          .width(PixState.windowWidth / 2)
          .padding(({ left: PixState.PageMarginValue, right: PixState.PageMarginValue }))
        }
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .bindSheet(this.showCommentPanel!!, this.CommentPanel(), {
        height: '70%',
        dragBar: true,
        onWillAppear: () => {},
        onWillDisappear: () => {
        }
      })
      this.FloatingControlButton()

      if (this.showLargeImage) {
        PixivImageViewer({
          imageUrls: this.iDV.imageList,
          startIndex: this.currentImageIndex,
          bookmarked: this.iDV.isBookmarked,
          onClose: () => {
            this.onImageLarge(false)
          },
          onDownload: (index) => {
            this.iDV.downloadCurrentImage(index);
            if (appSettings.collecting_when_download) {
              this.iDV.bookmarkOrCancel(true)
            }
          },
          onShare: (url, index) => {
            this.shareViewerImage(url, index)
          },
          onBookmark: (index) => {
            this.iDV.bookmarkOrCancel(!this.iDV.isBookmarked)
          },
          onZoomChange: (zoomed) => {
            this.onViewerZoom(zoomed)
          }
        })
          .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 })
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: curves.springMotion(0.42, 0.8) }))
      }
    }
  }
  }

  /** 分享查看器当前图片：按查看画质取到沙箱缓存后以文件形式拉起分享面板 */
  private shareViewerImage(url: string, index: number): void {
    const detail = this.iDV.detailData;
    if (!detail) return;
    const dot = url.lastIndexOf('.');
    const ext = dot >= 0 ? url.substring(dot) : '.jpg';
    const cachePath = `${_PixState.Context.cacheDir}/share/${detail.id}_p${index}${ext}`;
    const pageSuffix = detail.page_count > 1 ? ` P${index + 1}` : '';
    ShareUtil.shareRemoteImage(url, cachePath, `${detail.title}${pageSuffix}`,
      detail.user?.name ? `画师：${detail.user.name}` : undefined);
  }

  /**
   * 悬浮控制 tab：下载 + 收藏（竖式双按钮，保留智感握姿光效）
   */
  @Builder
  FloatingControlButton() {
    Column({ space: 4 }) {
      // 下载按钮
      Row() {
        SymbolGlyph($r('sys.symbol.circle_and_arrow_down'))
          .fontSize(24).fontColor([Color.White])
      }
      .width(56)
      .height(52)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        if (this.iDV.isUgoira) {
          this.iDV.downloadUgoira();
        } else {
          this.iDV.downloadAllImages();
        }
        if (appSettings.collecting_when_download) {
          this.iDV.bookmarkOrCancel(true)
        }
      })
      // 分隔线
      Divider()
        .strokeWidth(0.5)
        .width(28)
        .color('#33FFFFFF')
      // 收藏按钮
      Row() {
        SymbolGlyph(this.iDV.isBookmarked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(27).fontColor([this.iDV.isBookmarked ? PixState.currentThemeColor : Color.White])
      }
      .width(56)
      .height(52)
      .justifyContent(FlexAlign.Center)
      .borderRadius(26)
      .backgroundColor(this.iDV.isBookmarked ? ColorUtils.getColorWithAlphaString(PixState.currentThemeColor, 30) : Color.Transparent)
      .onClick(() => {
        this.iDV.bookmarkOrCancel()
      })
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 4, bottom: 4 })
    .width(60)
    .borderRadius(30)
    .backgroundColor($r('sys.color.ohos_id_color_bottom_tab_icon_auxcolor_off02'))
    .offset({ x: PixState.buttonPosition === 0 ? -PixState.PageMarginValue : PixState.PageMarginValue, y: -PixState.windowHeight * 0.3 })
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.BRIGHT, // 组件自身发光效果（收藏态用底色高亮区分，不再用光源开关）
        illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER // 组件受光效果
      })
      .buildEffect())
  }

  @Builder
  IntroContent() {
    // 详情信息卡片
    ListItem() {
      this.InfoCard()
    }
    // 评论入口
    ListItem() {
      this.Comment()
    }
    // 相关推荐
    ListItem() {
      this.RelatedSection()
    }
  }

  /** 详情信息卡片 */
  @Builder
  InfoCard() {
    Column({ space: 12 }) {
      // 标题
      Text(this.iDV.detailData!.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      // 统计数据行：观看人数 + 喜欢数 + 时间
      Row({ space: 16 }) {
        Text($r('app.string.browse', this.iDV.detailData!.total_view))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
        Text($r('app.string.num_collection', this.iDV.detailData!.total_bookmarks))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
        // 格式化时间
        Text(this.iDV.formatDate(this.iDV.detailData!.create_date))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .width('100%')
      // 元数据行：ID + 分辨率
      Row({ space: 16 }) {
        Text(`插画ID: ${this.iDV.detailData!.id}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_fourth'))
        Text(`${this.iDV.detailData!.width} x ${this.iDV.detailData!.height}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_fourth'))
      }
      .width('100%')
      // 分割线
      Divider().color($r('sys.color.ohos_id_color_text_field_sub_bg'))

      // 作者行：头像 + 名称 + 关注按钮
      UserItem({
        user: this.iDV.detailData?.user,
        isFollow: this.iDV.isFollow,
        isFollowPrivate: this.iDV.isFollowPrivate,
        onButtonClick: (result: boolean, err?: string) => {
          this.iDV.followOrCancel(result, err)
        },
        onRestrictChange: (isPrivate: boolean) => {
          this.iDV.isFollowPrivate = isPrivate
        }
      })

      // 标签
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach(this.iDV.detailData!.tags, (tag: PixivTag) => {
          Row({ space: 4 }) {
            if (tagCollectionVM.isFavorite(tag.name)) {
              SymbolGlyph($r('sys.symbol.star_circle'))
                .fontSize(12)
                .fontColor(['#FF9500'])
            }
            // Shaft 式：原文为主行，官方译文为次行小字
            Column({ space: 2 }) {
              Text(`#${tag.name}`)
                .fontSize(13)
                .fontColor(tagCollectionVM.isFavorite(tag.name) ? '#FF9500' : PixState.currentThemeColor)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .maxLines(1)
              if (tag.translated_name && tag.translated_name !== tag.name) {
                Text(tag.translated_name)
                  .fontSize(10)
                  .fontColor(tagCollectionVM.isFavorite(tag.name) ? '#B3FF9500' : $r('sys.color.font_tertiary'))
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .maxLines(1)
              }
            }
            .alignItems(HorizontalAlign.Start)
            .constraintSize({ maxWidth: 300 })
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(tagCollectionVM.isFavorite(tag.name) ? '#26FF9500' : $r('app.color.brand_weak'))
          .borderRadius(UIConstants.RADIUS_PILL)
          .constraintSize({ maxWidth: '100%' })
          .onClick(() => {
            // 点击标签直接以该标签为关键词搜索（用原始标签名保证 exact_match_for_tags 精确匹配），
            // 关键词经路由参数传入，由搜索结果页 onReady 时发起搜索
            toastUtil.animateTo({
              curve: curves.interpolatingSpring(0, 1, 342, 38)
            }, () => {
              const p: SearchingPageParams = { keyword: tag.name, searchType: 'illust' };
              this.pageStack.pushPathByName('searching_page', p, false);
            })
          })
          .gesture(
            LongPressGesture({ repeat: false, duration: 400 })
              .onAction(() => {
                this.menuTagName = tag.name;
                this.showTagMenu = true;
              })
          )
          .bindMenu(this.showTagMenu && this.menuTagName === tag.name, this.TagMenu(tag), {
            placement: Placement.Bottom,
            backgroundBlurStyle: BlurStyle.Thin,
            onDisappear: () => {
              this.showTagMenu = false
            }
          })
        })
      }
      .width('100%')
    }
    .width('100%')
    .borderRadius(UIConstants.RADIUS_ITEM)
  }

  /** 评论入口 */
  @Builder
  Comment() {
    Row() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.ellipsis_message_1'))
          .fontSize(19)
          .fontColor([PixState.currentThemeColor])
        Text('查看评论')
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))
      }
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(19)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(UIConstants.RADIUS_ITEM)
    .onClick(() => {
      this.showCommentPanel = true
    })
  }

  @Builder
  CommentPanel() {
    CommentPanel({
      targetId: this.illustId,
      onClose: () => {
        this.showCommentPanel = false
      }
    })
  }

  /** 相关推荐 */
  @Builder
  RelatedSection() {
    Column({ space: 12 }) {
      // 标题
      Text($r('app.string.related_recommendations'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .padding({ left: 4 })

      // 网格布局
      Grid() {
        ForEach(this.iDV.relatedIllusts, (item: PixivIllust) => {
          GridItem() {
            PixivImageComponent({
              imageUrl: item.image_urls.square_medium,
              imageAspectRatio: 1,
              imageBorder: { radius: UIConstants.RADIUS_ITEM }
            })
          }
          .onClick(() => {
            // 点击推荐插画
            const index = this.iDV.relatedIllusts.findIndex(i => i.id === item.id);
            const params: DetailPageParams = {
              id: item.id,
              illust: item,
              swiperProvider: this.iDV,
              swiperIndex: index >= 0 ? index : 0
            }
            this.pageStack.pushPathByName('illust_detail', params, true);
          })
        })
      }
      .columnsTemplate(GridColumnsTemplate(PixState.widthBp))
      .columnsGap(3)
      .rowsGap(3)
      .width('100%')

      // 底部的加载更多按钮 / 状态提示
      if (this.iDV.hasMore) {
        Row() {
          if (this.iDV.isLoading) {
            LoadingProgress().width(20).height(20)
            Text() {
              Span($r('app.string.loading_recommendations'))
              Span('...')
            }.fontSize(14).margin({ left: 8 })
          } else {
            Text($r('app.string.load_more_recommendations')).fontSize(14).fontColor(PixState.currentThemeColor)
          }
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          if (!this.iDV.isLoading) {
            this.iDV.loadMore();
          }
        })
      } else if (this.iDV.relatedIllusts.length > 0) {
        Text($r('app.string.no_further_recommendations'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ top: 8, bottom: 8 })
      }
    }
    .width('100%')
    .borderRadius(12)
  }

}

