import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri, fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { _PixState } from '../../entryability/AppState';
import { PixivIllust } from '../../services/PixivTypes';
import { appSettings } from '../entity/SettingsModel';
import { directDownloader } from './network/DirectDownloader';
import { toastUtil } from './ToastUtils';
import { createLogger } from './Logger';

const logger = createLogger('ShareUtil');

/**
 * 系统分享工具：基于 Share Kit（@kit.ShareKit）拉起系统分享面板。
 * - 文本分享：作品按「分享文本格式」设置渲染模板，画师主页为固定格式；
 * - 图片分享：经下载引擎取到沙箱缓存后以文件 URI 分享（无需额外权限，面板对目标应用临时授权）。
 */
export class ShareUtil {

  /** 渲染作品分享文本：占位符规则与「分享文本格式」设置页（ShareFormat）一致 */
  static renderShareText(illust: PixivIllust): string {
    const tags = (illust.tags ?? []).map(tag => tag.name).join(', ');
    return appSettings.share_text
      .replace(/{title}/g, illust.title)
      .replace(/{illust_id}/g, illust.id.toString())
      .replace(/{user_name}/g, illust.user?.name ?? '')
      .replace(/{uid}/g, illust.user?.id?.toString() ?? '')
      .replace(/{tags}/g, tags);
  }

  /** 分享一段纯文本 */
  static shareText(text: string): void {
    ShareUtil.show(new systemShare.SharedData({
      utd: utd.UniformDataType.PLAIN_TEXT,
      content: text
    }), systemShare.SharePreviewMode.DEFAULT);
  }

  /** 分享作品：按「分享文本格式」设置渲染后的文本（默认含标题/画师/作品链接） */
  static shareIllustText(illust: PixivIllust): void {
    ShareUtil.shareText(ShareUtil.renderShareText(illust));
  }

  /** 分享画师主页：固定格式文本（画师名 + 主页链接） */
  static shareUserText(userId: number, userName: string): void {
    const lines: string[] = [];
    if (userName) {
      lines.push(`画师：${userName}`);
    }
    lines.push(`链接：https://www.pixiv.net/users/${userId}`);
    ShareUtil.shareText(lines.join('\n'));
  }

  /**
   * 分享网络图片：目标文件已缓存则直接分享，否则经下载引擎取回沙箱缓存后分享。
   * @param url 图片网络地址（由调用方决定画质，通常跟随查看画质）
   * @param cachePath 沙箱缓存目标路径（含扩展名，同名复用免重复下载）
   * @param title 分享记录标题（不传时面板显示文件名）
   * @param description 分享记录描述
   */
  static async shareRemoteImage(url: string, cachePath: string, title?: string, description?: string): Promise<void> {
    try {
      const dir = cachePath.substring(0, cachePath.lastIndexOf('/'));
      try {
        fs.mkdirSync(dir, true);
      } catch (e) {
        // 目录已存在等场景忽略，交由后续下载/分享流程报错
      }
      let exists = false;
      try {
        exists = await fs.access(cachePath);
      } catch (e) {
        exists = false;
      }
      if (!exists) {
        toastUtil.showToast({ message: '正在获取图片...' });
        const ok = await directDownloader.download(url, cachePath);
        if (!ok) {
          toastUtil.showToast({ message: '图片获取失败，请检查网络后重试' });
          return;
        }
      }
      const dot = cachePath.lastIndexOf('.');
      const ext = dot >= 0 ? cachePath.substring(dot) : '.jpg';
      // 按扩展名取精细化 utd（如 general.jpeg），帮助面板匹配精确的目标应用（Share Kit 体验规范）
      const utdTypeId = utd.getUniformDataTypeByFilenameExtension(ext, utd.UniformDataType.IMAGE);
      ShareUtil.show(new systemShare.SharedData({
        utd: utdTypeId,
        uri: fileUri.getUriFromPath(cachePath),
        title: title,
        description: description
      }), systemShare.SharePreviewMode.DETAIL);
    } catch (e) {
      logger.error(`shareRemoteImage failed: ${JSON.stringify(e)}`);
      toastUtil.showToast({ message: '分享失败' });
    }
  }

  /** 拉起系统分享面板（单选模式；失败统一 toast） */
  private static show(data: systemShare.SharedData, previewMode: systemShare.SharePreviewMode): void {
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    controller.show(_PixState.Context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: previewMode
    }).then(() => {
      logger.debug('share panel shown');
    }).catch((err: BusinessError) => {
      logger.error(`share panel error, code: ${err.code}, message: ${err.message}`);
      toastUtil.showToast({ message: '分享失败' });
    });
  }
}
