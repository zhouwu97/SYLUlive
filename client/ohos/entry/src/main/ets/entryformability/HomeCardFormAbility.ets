import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import HomeCardStore from '../homecard/HomeCardStore';

/** 管理互动卡片实例，保证应用进程未启动时仍可读取缓存快照。 */
export default class HomeCardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = `${want.parameters?.[formInfo.FormParam.IDENTITY_KEY] ?? ''}`;
    const formName = `${want.parameters?.[formInfo.FormParam.NAME_KEY] ?? ''}`;
    this.registerAndRefresh(formId, formName);
    return formBindingData.createFormBindingData(
      HomeCardStore.emptyBinding(formName),
    );
  }

  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    const formName = `${wantParams?.[formInfo.FormParam.NAME_KEY] ?? ''}`;
    if (formName.length > 0) {
      this.registerAndRefresh(formId, formName);
      return;
    }
    HomeCardStore.refreshAll(this.context);
  }

  onRemoveForm(formId: string): void {
    HomeCardStore.removeForm(this.context, formId);
  }

  onAcquireFormState(_: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  private async registerAndRefresh(formId: string, formName: string): Promise<void> {
    await HomeCardStore.registerForm(this.context, formId, formName);
    await HomeCardStore.updateForm(this.context, formId, formName);
  }
}
