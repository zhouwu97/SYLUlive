import {test, expect} from '@playwright/test';

test('基础协议门禁可恢复，教务专项授权单独勾选，不自动重放业务写入', async ({page}) => {
  let accepted = false;
  const confirmations: Record<string, unknown>[] = [], otherWrites: string[] = [];
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() !== 'GET') otherWrites.push(path);
    return route.fulfill({json: {items: []}});
  });
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 991, role: 'user', nickname: '协议测试同学'}}));
  await page.route('**/api/feedback/tickets?**', route => route.fulfill(accepted ? {json: {items: []}} : {status: 403, json: {code: 'legal_consent_required', message: '请先确认最新协议与隐私政策'}}));
  await page.route('**/api/user/legal-consents', route => {
    const body = route.request().postDataJSON();
    confirmations.push(body);
    if (!body.edu_data_consent_accepted) return route.fulfill({status: 400, json: {code: 'edu_data_consent_required', error: '请单独确认教务数据专项授权'}});
    accepted = true;
    return route.fulfill({json: {ok: true}});
  });
  await page.goto('feedback');
  const panel = page.getByRole('region', {name: '确认最新协议', exact: true});
  await expect(panel).toBeVisible();
  await expect(panel.getByRole('checkbox')).not.toBeChecked();
  await expect(panel.getByRole('button', {name: '确认协议', exact: true})).toBeDisabled();
  expect(confirmations).toHaveLength(0);
  await panel.getByRole('checkbox').check();
  await panel.getByRole('button', {name: '确认协议', exact: true}).click();
  const edu = panel.getByRole('checkbox', {name: /教务数据专项授权/});
  await expect(edu).not.toBeChecked();
  expect(confirmations).toEqual([{user_agreement_accepted: true, privacy_policy_accepted: true}]);
  await expect(panel.getByRole('link', {name: '教务数据专项授权'})).toHaveAttribute('href', '/privacy#edu-data-consent');
  await edu.check();
  await panel.getByRole('button', {name: '确认协议', exact: true}).click();
  await expect(panel).toHaveCount(0);
  expect(confirmations).toHaveLength(2);
  expect(otherWrites).toEqual([]);
});

test('协议确认失败保留勾选，可以明确重试；成功后不自动发布内容', async ({page}) => {
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 991, role: 'user', nickname: '协议测试同学'}}));
  let calls = 0;
  await page.route('**/api/user/legal-consents', route => {
    calls++;
    return route.fulfill(calls === 1 ? {status: 503, json: {message: '暂时不能保存确认'}} : {json: {ok: true}});
  });
  await page.goto('agreements');
  const panel = page.getByRole('region', {name: '确认最新协议', exact: true});
  await panel.getByRole('checkbox').check();
  await panel.getByRole('button', {name: '确认协议', exact: true}).click();
  await expect(panel.getByRole('alert')).toContainText('暂时不能保存确认');
  await expect(panel.getByRole('checkbox')).toBeChecked();
  expect(calls).toBe(1);
  await panel.getByRole('button', {name: '确认协议', exact: true}).click();
  await expect(page.getByText('协议已确认，请重新提交刚才的操作。', {exact: true})).toBeVisible();
  expect(calls).toBe(2);
});

test('提交工单被协议门禁拒绝时保留草稿，确认后由用户手动重提', async ({page}) => {
  let accepted = false, confirmations = 0;
  const submissions: Record<string, unknown>[] = [];
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 991, role: 'user', nickname: '协议测试同学'}}));
  await page.route('**/api/user/legal-consents', route => {
    confirmations++;
    accepted = true;
    return route.fulfill({json: {ok: true}});
  });
  await page.route('**/api/feedback/tickets', route => {
    submissions.push(route.request().postDataJSON());
    return route.fulfill(accepted ? {json: {id: 884}} : {status: 403, json: {code: 'legal_consent_required', message: '请先确认最新协议与隐私政策'}});
  });
  await page.goto('feedback');
  await page.getByRole('button', {name: '新建工单', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '提交反馈', exact: true});
  await dialog.getByLabel('标题', {exact: true}).fill('课表导入失败的详细反馈');
  await dialog.getByLabel('具体描述', {exact: true}).fill('保留这段文字，确认协议后继续提交。');
  await dialog.getByRole('button', {name: '提交工单', exact: true}).click();
  const panel = dialog.getByRole('region', {name: '确认最新协议', exact: true});
  await expect(panel).toBeVisible();
  await expect(dialog.locator('form')).toHaveCount(1);
  expect(submissions).toHaveLength(1);
  await panel.getByRole('checkbox').check();
  await panel.getByRole('button', {name: '确认协议', exact: true}).click();
  await expect(dialog.getByRole('alert')).toHaveText('协议已确认，请重新提交当前内容');
  await expect(dialog.getByLabel('标题', {exact: true})).toHaveValue('课表导入失败的详细反馈');
  await expect(dialog.getByLabel('具体描述', {exact: true})).toHaveValue('保留这段文字，确认协议后继续提交。');
  expect(confirmations).toBe(1);
  expect(submissions).toHaveLength(1);
  await dialog.getByRole('button', {name: '提交工单', exact: true}).click();
  await expect(page).toHaveURL(/\/feedback\/884$/);
  expect(submissions).toHaveLength(2);
  expect(submissions[1]).toEqual(submissions[0]);
});
