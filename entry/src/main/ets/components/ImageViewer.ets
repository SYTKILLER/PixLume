import { curves } from '@kit.ArkUI';
import { PixState } from "../entryability/AppState";
import { PixivImageComponent } from "./PixivImage";
import { PixivImage } from '../services/PixivTypes';
import { appSettings } from '../common/entity/SettingsModel';
import { ImageUtils } from '../common/utils/ImageUtils';

const MAX_SCALE = 5;
const MIN_SCALE = 0.5;
const DOUBLE_TAP_SCALE = 2.5;
const DISMISS_THRESHOLD = 120;
// 放大态拖动顶边后，继续拖动超过该距离松手则翻到作品内上/下一张
const EDGE_PAGE_THRESHOLD = 60;
// 单击 vs 双击判定延时
const TAP_TIMEOUT = 280;

// 悬浮栏胶囊圆角
const UI_RADIUS = 28;

/** 可缩放单图：双指缩放 / 双击放大 / 放大拖动 / 1x 下滑关闭（官方《图片预览器》最佳实践） */
@ComponentV2
struct ZoomableImage {
  @Param imageUrl: string = ''
  @Event onSingleTap: () => void = () => {}
  @Event onDismiss: () => void = () => {}
  @Event onDragProgress: (progress: number) => void = () => {}
  @Event onZoomChanged: (zoomed: boolean) => void = () => {}
  // 放大态拖到边界后继续拖动松手翻页：direction 1=下一张，-1=上一张
  @Event onPageSwipe: (direction: number) => void = () => {}

  // 缩放与平移状态（.translate 与 .scale 属性组合：平移量在父坐标空间）
  @Local imgScale: number = 1
  @Local offsetX: number = 0
  @Local offsetY: number = 0
  // 下滑关闭跟手状态
  @Local dragY: number = 0
  @Local dragScale: number = 1
  // 组件区域尺寸（vp）
  private areaW: number = 0
  private areaH: number = 0
  // 平移手势参数用 options 动态管理：构造参数里的状态变量更新不可靠，
  // 放大后 direction 未切到 All 时横滑会穿透到外层 Swiper 导致切作品
  private panOption: PanGestureOptions = new PanGestureOptions({ fingers: 1, direction: PanDirection.Vertical, distance: 5 })
  // 捏合基准（onActionStart 定格，重触发时重新定格，等效官方 stash 模式）
  private pinchStartScale: number = 1
  private pinchStartOffsetX: number = 0
  private pinchStartOffsetY: number = 0
  // 捏合起始双指中心（组件中心相对坐标）
  private pinchStartCenterX: number = 0
  private pinchStartCenterY: number = 0
  // 拖动基准
  private panStartOffsetX: number = 0
  private panStartOffsetY: number = 0
  // 放大态拖动时未 clamp 的目标位移，与实际位移之差即顶边后的溢出量（翻页判定用）
  private panTargetX: number = 0
  // Parallel 组内仲裁：pinch 接管后 pan 冻结至自身 End，避免双方同时写位移
  private gestureOwner: string = ''
  private panSuperseded: boolean = false
  // 当前落指数（onTouch 计数）：判定回调据此拒绝双指期间的 Pan
  private touchCount: number = 0
  // 本触摸序列内 pinch/pan 已成功：抑制其后抬指误触单击
  private seqHadGesture: boolean = false
  // 放大态上报门控：捏合中只升不降，手势结束才回落，避免 Swiper 中途重新武装
  private reportedZoomed: boolean = false
  private singleTapTimer: number = -1
  // 双击成功时刻：count:1 单击手势对双击的第二击也会识别成功，需据此忽略
  private lastDoubleTapTime: number = 0
  // panOption 当前是否处于放大态方向，避免逐帧重复 set
  private panOptionZoomed: boolean = false

  aboutToDisappear(): void {
    if (this.singleTapTimer >= 0) {
      clearTimeout(this.singleTapTimer)
    }
  }

  /** imgScale 每次变化后同步平移手势方向：放大态全向接管拖动，1x 态仅纵向（横向让给 Swiper 翻页） */
  private syncPanDirection(): void {
    const zoomed = this.imgScale > 1.01
    if (zoomed === this.panOptionZoomed) {
      return
    }
    this.panOptionZoomed = zoomed
    this.panOption.setDirection(zoomed ? PanDirection.All : PanDirection.Vertical)
  }

  private clampBound(v: number, min: number, max: number): number {
    return Math.min(max, Math.max(min, v))
  }

  private clampOffsetFor(value: number, axisIsX: boolean, scale: number): number {
    const area = axisIsX ? this.areaW : this.areaH
    const max = Math.max(0, (area * scale - area) / 2)
    return this.clampBound(value, -max, max)
  }

  private clampOffset(value: number, axisIsX: boolean): number {
    return this.clampOffsetFor(value, axisIsX, this.imgScale)
  }

  /** 放大态变化上报：同值去重；捏合过程中只升不降 */
  private reportZoom(zoomed: boolean): void {
    if (zoomed === this.reportedZoomed) {
      return
    }
    this.reportedZoomed = zoomed
    this.onZoomChanged(zoomed)
  }

  private toggleZoom(tapLocalX?: number, tapLocalY?: number) {
    const zoomed = this.imgScale > 1.01
    this.getUIContext().animateTo({ duration: 280, curve: curves.springMotion(0.42, 0.8) }, () => {
      if (zoomed) {
        this.imgScale = 1
        this.offsetX = 0
        this.offsetY = 0
      } else {
        this.imgScale = DOUBLE_TAP_SCALE
        // 以双击点为焦点放大：点击点在放大后保持原位（参数缺失时退回居中放大）
        const fx = (tapLocalX ?? this.areaW / 2) - this.areaW / 2
        const fy = (tapLocalY ?? this.areaH / 2) - this.areaH / 2
        const k = DOUBLE_TAP_SCALE
        this.offsetX = this.clampOffsetFor(fx * (1 - k), true, k)
        this.offsetY = this.clampOffsetFor(fy * (1 - k), false, k)
      }
    })
    this.syncPanDirection()
    this.reportZoom(!zoomed)
  }

  build() {
    // 三层结构：手势绑定在最外层无变换的全屏宿主上——带 translate 的节点命中区域会随
    // 平移移动，图片拖出屏幕后触摸点落在其区域外，整棵子树手势全部失灵（放大拖动后
    // 手势"错乱"的根因）；平移/缩放只作用于内层内容节点
    // 变换拆两层：ArkUI 图形变换按 translate→scale 固定顺序合成，同层挂载时平移量会被
    // 缩放（视觉位移 = offset × scale）导致不跟手；拆开让平移保持屏幕坐标 1:1
    Column() {
      Column() {
        Stack() {
          PixivImageComponent({
            imageUrl: this.imageUrl,
            imageObjectFit: ImageFit.Contain,
            imageWidth: '100%',
            imageHeight: '100%',
            needMask: false
          })
        }
        .width('100%')
        .height('100%')
        .scale({ x: this.imgScale * this.dragScale, y: this.imgScale * this.dragScale })
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.offsetX, y: this.offsetY + this.dragY })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, newArea: Area) => {
      this.areaW = newArea.width as number
      this.areaH = newArea.height as number
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        if (this.touchCount === 0) {
          this.seqHadGesture = false
        }
        this.touchCount++
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.touchCount = Math.max(0, this.touchCount - 1)
      }
    })
    // 双指落屏期间拒绝 Pan（官方手势拦截方案）：从识别层面杜绝 Pan 抢跑，捏合可稳定接管
    .onGestureJudgeBegin((gestureInfo: GestureInfo, event: BaseGestureEvent) => {
      if (gestureInfo.type === GestureControl.GestureType.PAN_GESTURE &&
        (this.touchCount >= 2 || event.fingerList.length > 1)) {
        return GestureJudgeResult.REJECT
      }
      return GestureJudgeResult.CONTINUE
    })
    // 单双击并行组（官方单双击冲突方案）：双击优先识别，单击经 TAP_TIMEOUT 延时与双击互斥；
    // 两组独立声明时单击会先识别成功导致双击永远失效
    .gesture(GestureGroup(GestureMode.Parallel,
      TapGesture({ count: 2 })
        .onAction((event: GestureEvent) => {
          this.lastDoubleTapTime = Date.now()
          if (this.singleTapTimer >= 0) {
            clearTimeout(this.singleTapTimer)
            this.singleTapTimer = -1
          }
          // fingerList[0] 即双击手指：localX/Y 相对组件左上角（vp），供焦点放大使用
          const finger = event.fingerList[0]
          this.toggleZoom(finger?.localX, finger?.localY)
        }),
      TapGesture({ count: 1 })
        .onAction(() => {
          // 本序列捏合/拖动已成功时抬指不是单击（pan/pinch 成功后 Tap 仍会识别成功）
          if (this.seqHadGesture) {
            return
          }
          // 双击的第二击也会让单击手势成功并重设定时器：落在双击窗口内则忽略，
          // 否则定时器在双击缩放后到期，工具栏被误切换
          if (Date.now() - this.lastDoubleTapTime < TAP_TIMEOUT) {
            return
          }
          if (this.singleTapTimer >= 0) {
            clearTimeout(this.singleTapTimer)
          }
          this.singleTapTimer = setTimeout(() => {
            this.singleTapTimer = -1
            this.onSingleTap()
          }, TAP_TIMEOUT)
        })
    ))
    // 缩放与拖动并行组 + 手写仲裁（官方 imageviewer 同款拓扑）：Exclusive 会让先达阈值者
    // 独吞识别导致捏合失灵；并行后由 gestureOwner 决定驱动方，捏合可随时接管拖动
    .gesture(GestureGroup(GestureMode.Parallel,
      // distance:1 降低起手死区：双指一张合即达成，稳定先于 Pan/Swiper（官方同款参数）
      PinchGesture({ fingers: 2, distance: 1 })
        .onActionStart((event: GestureEvent) => {
          this.seqHadGesture = true
          this.gestureOwner = 'pinch'
          this.panSuperseded = true
          // 接管可能进行中的下拉关闭跟手态
          if (this.dragY !== 0 || this.dragScale !== 1) {
            this.dragY = 0
            this.dragScale = 1
            this.onDragProgress(0)
          }
          this.pinchStartScale = this.imgScale
          this.pinchStartOffsetX = this.offsetX
          this.pinchStartOffsetY = this.offsetY
          this.pinchStartCenterX = event.pinchCenterX - this.areaW / 2
          this.pinchStartCenterY = event.pinchCenterY - this.areaH / 2
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.gestureOwner !== 'pinch' || event.scale <= 0) {
            return
          }
          const newScale = this.clampBound(this.pinchStartScale * event.scale, MIN_SCALE, MAX_SCALE)
          // 标准粘指公式：捏合起始焦点下的内容点始终跟随双指中心（含中心移动），
          // offset = C_now − (C0 − O0)·k；clamp 须用 newScale（用上一帧 scale 会逐帧漂移）
          const k = newScale / this.pinchStartScale
          const cx = event.pinchCenterX - this.areaW / 2
          const cy = event.pinchCenterY - this.areaH / 2
          this.imgScale = newScale
          if (newScale <= 1.001) {
            this.offsetX = 0
            this.offsetY = 0
          } else {
            this.offsetX = this.clampOffsetFor(cx - (this.pinchStartCenterX - this.pinchStartOffsetX) * k, true, newScale)
            this.offsetY = this.clampOffsetFor(cy - (this.pinchStartCenterY - this.pinchStartOffsetY) * k, false, newScale)
          }
          this.syncPanDirection()
          if (newScale > 1.01) {
            this.reportZoom(true)
          }
        })
        .onActionEnd((_event: GestureEvent) => {
          if (this.gestureOwner === 'pinch') {
            this.gestureOwner = ''
          }
          if (this.imgScale <= 1.2) {
            // 接近/低于 1x 时回弹归位，避免残留微小缩放
            this.getUIContext().animateTo({ duration: 250, curve: curves.springMotion(0.42, 0.8) }, () => {
              this.imgScale = 1
              this.offsetX = 0
              this.offsetY = 0
            })
            this.syncPanDirection()
            this.reportZoom(false)
          }
        }),
      // 未放大时仅接管纵向手势（下拉关闭），横向让给 Swiper 翻页；放大后全向接管自由拖动
      PanGesture(this.panOption)
        .onActionStart((_event: GestureEvent) => {
          if (this.gestureOwner !== '') {
            return // pinch 已接管（judge 通常已拦截，此处兜底）
          }
          this.gestureOwner = 'pan'
          this.panSuperseded = false
          this.seqHadGesture = true
          this.panStartOffsetX = this.offsetX
          this.panStartOffsetY = this.offsetY
          this.panTargetX = this.offsetX
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.gestureOwner !== 'pan' || this.panSuperseded) {
            return
          }
          // 拖动中落下第二指：冻结等待 pinch 接管（judge 已在识别期拦截，此处兜底）
          if (this.touchCount >= 2) {
            return
          }
          if (this.imgScale > 1.01) {
            // 放大态：自由拖动并限制边界，panTargetX 保留未 clamp 的目标位移
            this.panTargetX = this.panStartOffsetX + event.offsetX
            this.offsetX = this.clampOffset(this.panTargetX, true)
            this.offsetY = this.clampOffset(this.panStartOffsetY + event.offsetY, false)
          } else {
            // 1x 态：仅响应下拉关闭
            const dy = event.offsetY
            if (dy > 0) {
              this.dragY = dy
              this.dragScale = Math.max(0.92, 1 - dy / 1500)
              this.onDragProgress(this.clampBound(dy / 300, 0, 1))
            }
          }
        })
        .onActionEnd((_event: GestureEvent) => {
          const superseded = this.panSuperseded
          if (this.gestureOwner === 'pan') {
            this.gestureOwner = ''
          }
          this.panSuperseded = false
          if (superseded) {
            return // 被 pinch 接管过：本次拖动不再判定翻页/关闭
          }
          if (this.imgScale > 1.01) {
            // 放大态：图片顶在边界后继续拖动的溢出量超过阈值松手 → 作品内翻页
            const overflow = this.panTargetX - this.offsetX
            if (overflow > EDGE_PAGE_THRESHOLD) {
              this.onPageSwipe(-1)
            } else if (overflow < -EDGE_PAGE_THRESHOLD) {
              this.onPageSwipe(1)
            }
            return
          }
          if (this.dragY > DISMISS_THRESHOLD) {
            this.onDismiss()
            this.dragY = 0
            this.dragScale = 1
            this.onDragProgress(0)
          } else {
            this.getUIContext().animateTo({ duration: 250, curve: curves.springMotion(0.42, 0.8) }, () => {
              this.dragY = 0
              this.dragScale = 1
            })
            this.onDragProgress(0)
          }
        })
    ))
  }
}

/** 全屏看图器：Swiper 翻页 + 悬浮毛玻璃顶栏/工具栏 */
@ComponentV2
export struct PixivImageViewer {
  // 图片URL列表 (保持接收完整的 PixivImage 对象)
  @Param imageUrls: PixivImage[] = [];
  // 初始索引
  @Param startIndex: number = 0;
  // 当前作品是否已收藏
  @Param bookmarked: boolean = false;
  // 当前索引 (用于显示页码)
  @Local currentIndex: number = 0;
  // 顶栏/工具栏显隐
  @Local barsVisible: boolean = true;
  // 放大态禁用翻页
  @Local imageZoomed: boolean = false;
  // 背景透明度（下拉跟手渐隐）
  @Local bgOpacity: number = 1;
  // 按钮弹跳动效触发器
  @Local bookmarkBounce: number = 0;
  @Local downloadBounce: number = 0;
  @Local shareBounce: number = 0;

  private swiperController: SwiperController = new SwiperController();
  // Swiper 容器当前落指数：判定回调据此在双指期间拒绝内置翻页手势
  private swiperTouchCount: number = 0;

  // 事件：关闭查看器
  @Event onClose: () => void = () => {};
  // 事件：下载当前图片
  @Event onDownload: (index: number) => void = () => {};
  // 事件：分享当前图片
  @Event onShare: (url: string, index: number) => void = () => {};
  // 事件：收藏/取消收藏当前作品
  @Event onBookmark: (index: number) => void = () => {};
  // 事件：放大态变化（供宿主禁用外层作品切换 Swiper，防止横滑穿透）
  @Event onZoomChange: (zoomed: boolean) => void = () => {};

  aboutToAppear(): void {
    this.currentIndex = this.startIndex;
  }

  private toggleBars() {
    this.barsVisible = !this.barsVisible
  }

  @Builder
  BarButton(icon: Resource, bounce: number, action: () => void, activeColor?: ResourceColor) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([activeColor ?? Color.White])
        .symbolShadow({ radius: 8, color: '#66000000' })
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE), bounce)
    }
    .width(48)
    .height(48)
    .borderRadius(24)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#1AFFFFFF')
    .onClick(() => {
      action()
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 黑色背景（下拉关闭时跟手渐隐）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
        .opacity(this.bgOpacity)

      // Swiper 图片浏览区
      Swiper(this.swiperController) {
        ForEach(this.imageUrls, (image: PixivImage, index: number) => {
          ZoomableImage({
            imageUrl: ImageUtils.getImageUrlByQuality(image, appSettings.image_view_quality),
            onSingleTap: () => {
              this.toggleBars()
            },
            onDismiss: () => {
              this.onClose()
            },
            onDragProgress: (progress: number) => {
              this.bgOpacity = 1 - progress * 0.9
            },
            onZoomChanged: (zoomed: boolean) => {
              this.imageZoomed = zoomed
              if (zoomed) {
                this.barsVisible = false
              }
              this.onZoomChange(zoomed)
            },
            onPageSwipe: (direction: number) => {
              // 放大态拖到边界松手翻页：新图从 1x 开始，同时恢复 Swiper 手势翻页
              if (direction > 0 && this.currentIndex < this.imageUrls.length - 1) {
                this.imageZoomed = false
                this.swiperController.showNext()
              } else if (direction < 0 && this.currentIndex > 0) {
                this.imageZoomed = false
                this.swiperController.showPrevious()
              }
            }
          })
        }, (image: PixivImage, index: number): string => `${index}_${image.medium}`)
      }
      .index(this.startIndex)
      .loop(false)
      .indicator(false)
      .cachedCount(1)
      .disableSwipe(this.imageZoomed)
      .onChange((index) => {
        this.currentIndex = index;
      })
      .width('100%')
      .height('100%')
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.swiperTouchCount++
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.swiperTouchCount = Math.max(0, this.swiperTouchCount - 1)
        }
      })
      // 1x 双指横滑时拒绝 Swiper 内置翻页手势，让位图片捏合缩放（子组件 judge 的对侧补强）
      .onGestureJudgeBegin((gestureInfo: GestureInfo, _event: BaseGestureEvent) => {
        if (gestureInfo.type === GestureControl.GestureType.PAN_GESTURE && this.swiperTouchCount >= 2) {
          return GestureJudgeResult.REJECT
        }
        return GestureJudgeResult.CONTINUE
      })

      // 顶栏 + 底部工具栏覆盖层（不拦截图片区点击）
      Column() {
        // 顶部悬浮栏：关闭 + 页码
        Row({ space: 12 }) {
          this.BarButton($r('sys.symbol.chevron_left'), 0, (): void => {
            this.onClose()
          })
          Blank()
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.shutter_photo'))
              .fontSize(16)
              .fontColor([Color.White])
            Text(`${this.currentIndex + 1} / ${this.imageUrls.length}`)
              .fontSize(14)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(UI_RADIUS)
          .backgroundColor('#33000000')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: PixState.topRectHeight + 12 })
        .opacity(this.barsVisible ? 1 : 0)
        .translate({ y: this.barsVisible ? 0 : -16 })
        .visibility(this.barsVisible ? Visibility.Visible : Visibility.Hidden)
        .animation({ duration: 250, curve: Curve.Ease })

        Blank()

        // 底部悬浮工具栏：收藏 / 下载 / 分享
        Row({ space: 28 }) {
          this.BarButton(this.bookmarked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            this.bookmarkBounce, (): void => {
              this.bookmarkBounce++
              this.onBookmark(this.currentIndex)
            }, this.bookmarked ? '#FF3B30' : undefined)
          this.BarButton($r('sys.symbol.circle_and_arrow_down'), this.downloadBounce, (): void => {
            this.downloadBounce++
            this.onDownload(this.currentIndex)
          })
          this.BarButton($r('sys.symbol.share'), this.shareBounce, (): void => {
            this.shareBounce++
            const image = this.imageUrls[this.currentIndex]
            // 分享的链接也跟随当前展示的质量设置
            const currentUrl = ImageUtils.getImageUrlByQuality(image, appSettings.image_view_quality);
            this.onShare(currentUrl, this.currentIndex)
          })
        }
        .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        .margin({ bottom: PixState.bottomRectHeight + 16 })
        .borderRadius(UI_RADIUS)
        .backgroundBlurStyle(BlurStyle.Thin, {
          colorMode: ThemeColorMode.DARK,
          adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundColor('#33000000')
        .border({ width: 0.5, color: '#33FFFFFF' })
        .opacity(this.barsVisible ? 1 : 0)
        .translate({ y: this.barsVisible ? 0 : 24 })
        .visibility(this.barsVisible ? Visibility.Visible : Visibility.Hidden)
        .animation({ duration: 250, curve: Curve.Ease })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }
}
