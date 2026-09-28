import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { PixivImageComponent } from './PixivImage';
import { pixiv } from '../services/PixivService';
import { UgoiraMetadata } from '../services/PixivTypes';
import { ensureUgoiraFrames, loadCachedUgoiraFrames, UgoiraFrames, UgoiraSize } from '../common/utils/UgoiraCache';
import { createLogger } from '../common/utils/Logger';
import { _PixState } from '../entryability/AppState';

const logger = createLogger('UgoiraPlayer')

/** 播放用帧包档位：600x600 加载快、逐帧解码内存可控（约 1.4MB/帧） */
const PLAY_SIZE: UgoiraSize = '600x600'

/** ImageAnimator 帧信息：src 必须是沙箱 URI（fileUri.getUriFromPath 转换），duration 单位 ms */
interface UgoiraFrameView {
  src: string
  duration: number
}

/**
 * 动图（ugoira）播放器：静态预览图打底，点击后拉取元数据 → 下载 600x600 帧包 → 解压 →
 * ImageAnimator 按每帧 delay 循环播放；已缓存的再次进入自动播放。
 * 播放中点击暂停/恢复；monitorInvisibleArea 使其在滑出可视区（Swiper 切页）时自动暂停。
 */
@ComponentV2
export struct UgoiraPlayer {

  @Param @Require illustId: number
  @Param previewUrl: string = ''
  /** 作品宽高比（width/height），用于在图片加载前撑起正确尺寸（命名避开内置属性 aspectRatio） */
  @Param frameRatio: number | undefined = undefined

  @Local framesReady: boolean = false
  @Local frames: UgoiraFrameView[] = []
  @Local playing: boolean = false
  @Local loading: boolean = false
  @Local progress: number = 0
  @Local errorText: string = ''

  async aboutToAppear(): Promise<void> {
    // 帧缓存命中（此前播过）→ 自动播放；未命中保持预览图等待手动点击（省流量）
    try {
      const cached = await loadCachedUgoiraFrames(_PixState.Context as common.Context, this.illustId, PLAY_SIZE)
      if (cached) {
        this.applyFrames(cached)
      }
    } catch (e) {
      logger.warn(`cache check failed: ${getErrMsg(e)}`)
    }
  }

  /** 首次播放：拉元数据 → 下载帧包 → 解压 → 就绪即播放 */
  private async startPlay(): Promise<void> {
    if (this.loading) return
    this.loading = true
    this.errorText = ''
    this.progress = 0
    try {
      const context = _PixState.Context as common.Context
      const meta: UgoiraMetadata = await pixiv.getUgoiraMetadata(this.illustId)
      const frames = await ensureUgoiraFrames(context, this.illustId, meta, PLAY_SIZE,
        (percent: number) => {
          this.progress = percent
        })
      this.applyFrames(frames)
    } catch (e) {
      logger.error(`startPlay failed: ${getErrMsg(e)}`)
      this.errorText = '加载失败，点击重试'
    } finally {
      this.loading = false
    }
  }

  private applyFrames(frames: UgoiraFrames): void {
    this.frames = frames.paths.map((path: string, index: number) => {
      return {
        src: fileUri.getUriFromPath(path),
        // 下限 20ms 防止异常 0 值导致闪烁
        duration: Math.max(20, frames.delays[index] || 50)
      } as UgoiraFrameView
    })
    this.framesReady = true
    this.playing = true
  }

  private handleTap(): void {
    if (this.loading) return
    if (this.errorText !== '' || !this.framesReady) {
      this.startPlay()
      return
    }
    this.playing = !this.playing
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 预览图打底：播放前是海报帧，播放后兜底（ImageAnimator 渲染覆盖其上）
      PixivImageComponent({
        imageUrl: this.previewUrl,
        imageObjectFit: ImageFit.Contain,
        imageBorder: { radius: 0 },
        imageWidth: '100%',
        imageHeight: '100%',
      })

      if (this.framesReady && this.frames.length > 0) {
        // images 不支持动态更新：仅在帧就绪后条件渲染，一次成型；state 切换只控制播放状态
        ImageAnimator()
          .images(this.frames)
          .state(this.playing ? AnimationStatus.Running : AnimationStatus.Paused)
          .iterations(-1)
          .fixedSize(true)
          .monitorInvisibleArea(true)
          .width('100%')
          .height('100%')
      }

      if (this.loading) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Ring })
          .width(44)
          .height(44)
          .color(Color.White)
          .style({ strokeWidth: 4 })
      } else if (this.errorText !== '') {
        Text(this.errorText)
          .fontSize(13)
          .fontColor(Color.White)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('#80000000')
          .borderRadius(8)
      } else if (!this.playing) {
        // 暂停/未开始：显示播放按钮；播放中无覆盖层保持画面干净
        Row() {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(26)
            .fontColor([Color.White])
        }
        .width(56)
        .height(56)
        .justifyContent(FlexAlign.Center)
        .borderRadius(28)
        .backgroundColor('#66000000')
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 200 })
    .aspectRatio(this.frameRatio)
    .onClick(() => this.handleTap())
  }
}

function getErrMsg(e: Object): string {
  const err = e as Error
  return err?.message ?? String(e)
}
