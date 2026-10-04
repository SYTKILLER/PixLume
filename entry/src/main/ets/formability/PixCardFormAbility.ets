import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { widgetService } from '../common/utils/widget/WidgetService';
import { createLogger } from '../common/utils/Logger';

const logger = createLogger('PixCardFormAbility')

/**
 * 灵感图卡卡片扩展：卡片进程短生命周期（回调后约 5 秒），
 * 所有换图动作（加桌/刷新按钮/退出应用触发的 reloadForms）都走 WidgetService.refreshOne。
 */
export default class PixCardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY]?.toString() ?? ''
    logger.info(`onAddForm: ${formId}`)
    const data = widgetService.buildInitialData(this.context)
    // 先返回缓存图/占位，再在 5 秒生命窗内异步拉新图；未完成则由用户点刷新按钮补一次
    widgetService.refreshOne(this.context, formId)
    return formBindingData.createFormBindingData(data)
  }

  async onFormEvent(formId: string, message: string): Promise<void> {
    logger.info(`onFormEvent: ${formId}, msg=${message}`)
    await widgetService.refreshOne(this.context, formId)
  }

  async onUpdateForm(formId: string): Promise<void> {
    logger.info(`onUpdateForm: ${formId}`)
    await widgetService.refreshOne(this.context, formId)
  }

  onRemoveForm(formId: string): void {
    logger.info(`onRemoveForm: ${formId}`)
    widgetService.onFormRemoved(this.context, formId)
  }
}
