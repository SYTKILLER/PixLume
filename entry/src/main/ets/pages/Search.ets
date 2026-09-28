import { SearchingPageParams } from "../viewmodel/SearchViewModel";
import { PixivImageComponent } from "../components/PixivImage";
import { PixState } from "../entryability/AppState";
import { PixivTrendingTag } from "../services/PixivTypes";
import { GridColumnsTemplate } from "../common/utils/breakpoint/BreakPoint";
import { toastUtil } from "../common/utils/ToastUtils";
import { searchVM } from "../viewmodel/SearchViewModel";
import { curves } from "@kit.ArkUI";
import { DetailPageParams } from "../common/entity/DetailEntity";
import SearchHistoryInfo from "../common/entity/SearchHistoryInfo";
import { appSettings } from "../common/entity/SettingsModel";
import { KeywordView } from "../viewmodel/TagCollectionVM";

// 搜索历史胶囊圆角
const UI_RADIUS_PILL = 999;
// 历史胶囊行高估算：字号13行高约18 + 上下padding 14 = 32，加上下margin 8 = 每行40
const HISTORY_ROW_HEIGHT = 40;
// 搜索历史区正好可见 3 行，超出滚动
const HISTORY_MAX_HEIGHT = HISTORY_ROW_HEIGHT * 3;
// 猜你喜欢两行胶囊行高估算：字号13行高约18 + 译文行16 + 上下padding 14 = 48，加margin 8 = 每行56
const GUESS_ROW_HEIGHT = 56;
// 猜你喜欢区正好可见 2 行，超出滚动
const GUESS_MAX_HEIGHT = GUESS_ROW_HEIGHT * 2;


@ComponentV2
export struct SearchPage {

  private pageInfos: NavPathStack = new NavPathStack();
  aboutToAppear(): void {
    setTimeout(() => {
      this.pageInfos.pushPath({ name: 'search_page' }, false)
    }, 300)
  }

  build() {
    Navigation(this.pageInfos) {
    }
    .hideToolBar(true)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
  }

}

@Builder
export function SearchContentBuilder() {
  SearchContent()
}

@ComponentV2
export struct SearchContent {

  private pageInfos: NavPathStack = new NavPathStack();

  build() {
    NavDestination() {
      Column({space: 10}) {
        Text($r('app.string.search'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        Search({ value: searchVM.keyword!!, placeholder: $r('app.string.search_placeholder_1') })
          .defaultFocus(false)
          .focusOnTouch(false)
          .searchButton($r('sys.symbol.picture_star_fill'))
          .geometryTransition('SEARCH_ID', { follow: true })
          .transition(TransitionEffect.OPACITY.animation({ duration: 350, curve: Curve.Friction }))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Up) {
              this.getUIContext().animateTo({
                curve: curves.interpolatingSpring(0, 1, 342, 38)
              }, () => {
                this.pageInfos.pushPath({ name: 'searching_page' }, false);
              })
            }
          })
          .onSubmit(() => {
            // TODO 拉起图片选择以图搜图
            toastUtil.showToast({ message: '开发中-以图搜图' })
          })

        List({ space: 10 }) {
          // 搜索历史
          if (searchVM.searchHistory.length > 0) {
            ListItem() {
              Column({ space: 5 }) {
                this.historyTitle()
                Scroll() {
                  Flex({ alignItems: ItemAlign.Start, justifyContent: FlexAlign.Start, wrap: FlexWrap.Wrap }) {
                    ForEach(searchVM.searchHistory, (item: SearchHistoryInfo) => {
                      Stack() {
                        Text(item.keyword)
                          .backgroundColor($r('app.color.card_bg'))
                          .padding({ top: 7, bottom: 7, left: 14, right: 14 })
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .textAlign(TextAlign.Center)
                          .borderRadius(UI_RADIUS_PILL)
                          .border({ width: 0.5, color: $r('sys.color.comp_divider') })
                          .fontColor($r('sys.color.font_secondary'))
                          .fontWeight(FontWeight.Normal)
                          .fontSize(13)
                          .maxLines(1)
                          .margin(4)
                          .constraintSize({
                            minWidth: '15%',
                            maxWidth: '50%'
                          })
                        if (searchVM.searchHistoryEdit) {
                          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                            .fontSize(14)
                            .fontColor([$r('sys.color.font_tertiary')])
                        }
                      }.align(Alignment.TopEnd)
                      .gesture(
                        LongPressGesture()
                          .onAction((event: GestureEvent) => {
                            if (event) {
                              if (!searchVM.searchHistoryEdit) {
                                // 长按进入编辑模式
                                searchVM.searchHistoryEdit = true
                              }
                            }
                          }))
                      .gesture(
                        TapGesture({ count: 1 })
                          .onAction(async (event: GestureEvent) => {
                            if (event) {
                              if (searchVM.searchHistoryEdit) {
                                // 删除
                                if (item.id) {
                                  await searchVM.deleteSearch(item.id)
                                  toastUtil.showToast({ message: $r('app.string.deleted', item.keyword)})
                                }
                              } else {
                                // 根据当前模式决定搜索类型，关键词经路由参数传入，由搜索结果页 onReady 时发起搜索
                                const kw = item.keyword;
                                const st = appSettings.novel_mode ? 'novel' : 'illust';
                                // 使用动画跳转到搜索结果页面
                                toastUtil.animateTo({
                                  curve: curves.interpolatingSpring(0, 1, 342, 38)
                                }, () => {
                                  const p: SearchingPageParams = { keyword: kw, searchType: st };
                                  PixState.pageStack.pushPathByName('searching_page', p, false);
                                })
                              }
                            }
                          }))
                    }, (item: SearchHistoryInfo) => `${item.id}_${item.keyword}`)
                  }
                }
                .constraintSize({ maxHeight: HISTORY_MAX_HEIGHT })
                .nestedScroll({
                  scrollForward: NestedScrollMode.SELF_FIRST,
                  scrollBackward: NestedScrollMode.SELF_FIRST,
                })
              }
            }
          }
          // 猜你喜欢：随机展示收藏标签
          if (searchVM.guessYouLike.length > 0) {
            ListItem() {
              Column({ space: 5 }) {
                Row({ space: 10 }) {
                  Text($r('app.string.guess_you_like'))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                  Blank()
                  Text($r('app.string.refresh_batch'))
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_secondary'))
                    .onClick(() => {
                      searchVM.refreshGuessYouLike()
                    })
                }.width('100%')
                Scroll() {
                  Flex({ alignItems: ItemAlign.Start, justifyContent: FlexAlign.Start, wrap: FlexWrap.Wrap }) {
                    ForEach(searchVM.guessYouLike, (item: KeywordView) => {
                      // 结构与搜索历史胶囊保持一致：手势挂 Stack 外壳，样式与 margin 在内层
                      Stack() {
                        Column() {
                          Text(item.name)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .textAlign(TextAlign.Center)
                            .fontColor($r('sys.color.font_secondary'))
                            .fontWeight(FontWeight.Normal)
                            .fontSize(13)
                            .maxLines(1)
                          // 译文行：缺失时保留空位，保证胶囊等高、区域两行高度精确
                          Text(item.translated !== item.name ? item.translated : '')
                            .height(16)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .textAlign(TextAlign.Center)
                            .fontColor($r('sys.color.font_tertiary'))
                            .fontSize(11)
                            .maxLines(1)
                        }
                        .backgroundColor($r('app.color.card_bg'))
                        .padding({ top: 7, bottom: 7, left: 14, right: 14 })
                        .borderRadius(UI_RADIUS_PILL)
                        .border({ width: 0.5, color: $r('sys.color.comp_divider') })
                        .margin(4)
                        .constraintSize({
                          minWidth: '15%',
                          maxWidth: '50%'
                        })
                      }
                      .align(Alignment.TopEnd)
                      .gesture(
                        TapGesture({ count: 1 })
                          .onAction(async (event: GestureEvent) => {
                            if (event) {
                              // 用收藏的原始标签名保证精确匹配，推到全局页面栈使其盖住页签容器，成为真正的二级页
                              const kw = item.name;
                              const st = appSettings.novel_mode ? 'novel' : 'illust';
                              toastUtil.animateTo({
                                curve: curves.interpolatingSpring(0, 1, 342, 38)
                              }, () => {
                                const p: SearchingPageParams = { keyword: kw, searchType: st };
                                PixState.pageStack.pushPathByName('searching_page', p, false);
                              })
                            }
                          }))
                    }, (item: KeywordView) => item.name)
                  }
                }
                .constraintSize({ maxHeight: GUESS_MAX_HEIGHT })
                .nestedScroll({
                  scrollForward: NestedScrollMode.SELF_FIRST,
                  scrollBackward: NestedScrollMode.SELF_FIRST,
                })
              }
            }
          }
          ListItem() {
            Column({ space: 10 }) {
              // 推荐标签
              Text($r('app.string.recommend_tag'))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
              Grid() {
                ForEach(searchVM.trendingTags, (item: PixivTrendingTag) => {
                  GridItem() {
                    Stack() {
                      // 封面图
                      PixivImageComponent({
                        imageUrl: item.illust.image_urls.square_medium,
                        imageAspectRatio: 1,
                        imageBorder: { radius: 12 },
                        needMask: true
                      })
                      // 标签名
                      Text() {
                        Span('#')
                        Span(item.translated_name || item.tag)
                      }
                      .fontSize(14)
                      .maxLines(1)
                      .fontColor($r('sys.color.font_on_primary'))
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignContent(Alignment.Bottom)
                  }
                  .gesture(
                    LongPressGesture()
                      .onAction((event: GestureEvent) => {
                        if (event) {
                          // 长按进入详情页
                          searchVM.handleLongPressGesture(item)
                        }
                      }))
                      .gesture(
                        TapGesture({ count: 1 })
                          .onAction((event: GestureEvent) => {
                            if (event) {
                              // 搜索关键词为标签名（优先使用翻译名），经路由参数传入，由搜索结果页 onReady 时发起搜索
                              const kw = item.translated_name || item.tag;
                              // 点击标签时，切到当前模式对应的搜索类型
                              const st = appSettings.novel_mode ? 'novel' : 'illust';
                              // 使用动画跳转到搜索结果页面
                              toastUtil.animateTo({
                                curve: curves.interpolatingSpring(0, 1, 342, 38)
                              }, () => {
                                const p: SearchingPageParams = { keyword: kw, searchType: st };
                                PixState.pageStack.pushPathByName('searching_page', p, false);
                              })
                            }
                          }))
                })
              }
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
              .nestedScroll(searchVM.nestedScrollOptions)
              .contentEndOffset((PixState.TabBarVertical ? 125 : 160) + PixState.bottomRectHeight)
              .columnsTemplate(GridColumnsTemplate(PixState.widthBp))
              .columnsGap(6)
              .rowsGap(8)
            }
            .justifyContent(FlexAlign.Start)
            .alignItems(HorizontalAlign.Start)
          }
        }
        .scrollBar(BarState.Off)
        // .onReachStart(() => {
        //   if (PixState.currentTab == 3 && PixState.TabBarVertical) {
        //     PixState.tabsController.changeIndex(2)
        //   }
        // })
        // .onReachEnd(() => {
        //   if (PixState.currentTab == 3 && PixState.TabBarVertical) {
        //     PixState.tabsController.changeIndex(4)
        //   }
        // })
      }
      .alignItems(HorizontalAlign.Start)
      .padding(({
        left: PixState.PageMarginValue,
        right: PixState.PageMarginValue
      }))
    }
    .hideToolBar(true)
    .hideTitleBar(true)
    .transition(TransitionEffect.OPACITY)
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
    .onBackPressed(() => {
      return true
    })
  }

  aboutToAppear(): void {
    searchVM.loadData()
  }

  @Builder
  historyTitle() {
    Row({ space: 10 }) {
      Text($r('app.string.search_history'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
      Blank()
      if (searchVM.searchHistoryEdit) {
        Text($r('app.string.cancel'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
          .onClick(() => {
            searchVM.searchHistoryEdit = false
          })
        SymbolGlyph($r('sys.symbol.ohos_trash_circle'))
          .fontSize(22)
          .fontColor([$r('sys.color.font_tertiary')])
          .onClick(() => {
            searchVM.clearSearchHistory()
          })
      }
    }.width('100%')
    .justifyContent(FlexAlign.Start)
  }

}