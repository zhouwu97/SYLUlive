import {test, expect} from '@playwright/test';

for (const width of [375, 1440]) {
  test(`QQ 绑定协议门禁弹窗保留连接码，失败可重试且不自动授权 ${width}`, async ({page}) => {
    await page.setViewportSize({width, height: 900});
    let accepted = false, confirmations = 0, lookups = 0;
    const otherWrites: string[] = [];
    await page.route('**/api/**', route => {
      if (route.request().method() !== 'GET') otherWrites.push(new URL(route.request().url()).pathname);
      return route.fulfill({json: {items: []}});
    });
    await page.route('**/api/user/profile', route => route.fulfill({json: {id: 991, role: 'user', nickname: '协议测试同学'}}));
    await page.route('**/api/connected-apps', route => route.fulfill({json: {bindings: []}}));
    await page.route('**/api/connected-apps/device-requests/lookup', route => {
      lookups++;
      return route.fulfill(accepted ? {json: {
        consent_id: 'synthetic-request', installation_name: '测试助手', installation_id: 'synthetic-install',
        user_code: 'ABCD-1234', requested_scopes: ['profile:read_minimal', 'checkin:write'],
        confirmation_nonce: 'synthetic-nonce', expires_at: '2099-01-01T00:00:00Z',
      }} : {status: 403, json: {code: 'legal_consent_required'}});
    });
    await page.route('**/api/user/legal-consents', route => {
      confirmations++;
      if (confirmations === 1) return route.fulfill({status: 503, json: {message: '暂时不能保存确认'}});
      accepted = true;
      return route.fulfill({json: {ok: true}});
    });
    await page.goto('connected-apps?purpose=personal&user_code=ABCD-1234');
    const lookup = page.getByRole('button', {name: '查看授权请求', exact: true});
    await lookup.click();
    const dialog = page.getByRole('dialog', {name: '确认协议后继续授权', exact: true});
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText('旧版本的同意不能代替对新内容的确认');
    await expect(dialog.getByRole('button', {name: '确认协议', exact: true})).toBeDisabled();
    await dialog.screenshot({path: test.info().outputPath(`binding-legal-${width}.png`)});
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await dialog.getByRole('button', {name: '关闭', exact: true}).click();
    await expect(dialog).toHaveCount(0);
    await expect(page.getByLabel('一次性连接码', {exact: true})).toHaveValue('ABCD-1234');
    expect(confirmations).toBe(0);
    await lookup.click();
    await dialog.getByRole('checkbox').check();
    await dialog.getByRole('button', {name: '确认协议', exact: true}).click();
    await expect(dialog.getByRole('alert')).toContainText('暂时不能保存确认');
    await expect(dialog.getByRole('checkbox')).toBeChecked();
    await dialog.getByRole('button', {name: '确认协议', exact: true}).click();
    await expect(dialog).toHaveCount(0);
    await expect(page.getByText('协议已确认，连接码和权限选择已保留。', {exact: false})).toBeVisible();
    expect(lookups).toBe(2);
    expect(otherWrites).toEqual([]);
    await lookup.click();
    await expect(page.getByRole('button', {name: '授权此助手', exact: true})).toBeVisible();
    expect(lookups).toBe(3);
    expect(otherWrites).toEqual([]);
  });
}

test('协议保存期间切换账号，旧确认结果不回填新账号', async ({page}) => {
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 991, role: 'user', nickname: '原账号'}}));
  await page.route('**/api/connected-apps', route => route.fulfill({json: {bindings: []}}));
  await page.route('**/api/connected-apps/device-requests/lookup', route => route.fulfill({status: 403, json: {code: 'legal_consent_required'}}));
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  let finished!: () => void;
  const completed = new Promise<void>(resolve => { finished = resolve; });
  await page.route('**/api/user/legal-consents', async route => {
    await pending;
    await route.fulfill({json: {ok: true}}).catch(() => {});
    finished();
  });
  await page.goto('connected-apps?purpose=personal&user_code=ABCD-1234');
  await page.getByRole('button', {name: '查看授权请求', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '确认协议后继续授权', exact: true});
  await dialog.getByRole('checkbox').check();
  const started = page.waitForRequest('**/api/user/legal-consents');
  await dialog.getByRole('button', {name: '确认协议', exact: true}).click();
  await started;
  await expect(dialog.getByRole('button', {name: '正在确认…', exact: true})).toBeDisabled();
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 992, role: 'user', nickname: '新账号'}}));
  await page.evaluate(() => { const channel = new BroadcastChannel('sylulive-auth'); channel.postMessage('changed'); channel.close(); });
  await expect(page.getByText(/当前校园账号：新账号/)).toBeVisible();
  release();
  await completed;
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText('协议已确认，连接码和权限选择已保留。', {exact: false})).toHaveCount(0);
  await expect(page.getByLabel('一次性连接码', {exact: true})).toHaveValue('ABCD-1234');
});

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
  await page.getByRole('button', {name: '创建工单', exact: true}).click();
  const dialog = page.getByRole('dialog', {name: '创建工单', exact: true});
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
