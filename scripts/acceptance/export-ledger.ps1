#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$report = Join-Path $root 'docs/reports/launch-acceptance'
$access = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'route-access.psd1')
$prefixes = 'ENV','AUTH','SETTINGS','SCHEDULE','ACADEMIC','COMMUNITY','WATER','POLL','CANTEEN','TEACHER','COMPETITION','PAPER','MESSAGE','EMOJI','AI','FEEDBACK','ADMIN','REGRESSION'
$counts = @{}

function New-Row($batch, $kind, $status, $entry = '', $api = '', $handler = '', $role = '', $note = '') {
    $counts[$batch] = 1 + [int]$counts[$batch]
    [pscustomobject][ordered]@{
        id = '{0}-{1:D3}' -f $prefixes[$batch], $counts[$batch]
        batch = $batch; kind = $kind; entry = $entry; entry_web = ''; role = $role; api = $api
        handler = $handler; tables = ''; admin_pair = ''; auto_evidence = ''; real_evidence = ''; status = $status; note = $note
    }
}

function Get-ApiBatch($path) {
    $path = $path -replace '^/api/(api/)?(?:(admin|super|user)/)?', '/'
    switch -Regex ($path) {
        '^/(health)(/|$)' { 0; break }
        '^/(auth|login[^/]*|logout|refresh|register[^/]*|password|send_code|verify_code|forgot_password|change_password|account(-security)?|email|legal-consents|terms|privacy|security|me|extension)(/|$)' { 1; break }
        '^/(themes?|nightmode|push-settings|avatar|background|profile|device_token|tutorial)(/|$)|^/users/:id/themes$' { 2; break }
        '^/(calendar(?:-action-drafts)?|campus-calendars|class-period-profiles)(/|$)|^/internal/mcp/schedule/' { 3; break }
        '^/(edu(?:-binding)?|erke|academic[^/]*|student-identity)(/|$)|^/internal/mcp/academic/' { 4; break }
        '^/water(?:/|$)' { 6; break }
        '^/(polls|lottery)(/|$)' { 7; break }
        '^/canteen[^/]*(/|$)' { 8; break }
        '^/(teacher[^/]*|course-(subjects|evaluations)|majors)(/|$)' { 9; break }
        '^/(competitions?|competition-[^/]+|team)(/|$)|^/internal/mcp/competition/' { 10; break }
        '^/exam-papers(/|$)' { 11; break }
        '^/(announcements|notices|messages|notifications|device_token|checkin|replies/received|likes/received)(/|$)' { 12; break }
        '^/(emoji[^/]*|stickers)(/|$)' { 13; break }
        '^/(ai[^/]*|connected-apps|managed-bot[^/]*|personal-snapshots|internal/mcp|device)(/|$)' { 14; break }
        '^/(feedback|app|app-releases|version)(/|$)' { 15; break }
        '^/(admin_logs|members|invite|invitations|candidates|removals|promote|stats|users)(/|$)' { 16; break }
        '^/(posts|replies|like[^/]*|bookmarks|topics|feed|search|reports|appeals|violations|rectification[^/]*|featured-applications|collaboration-applications|revision-proposals|community-rules|:id)(/|$)' { 5; break }
        default { 17 }
    }
}

function Get-SwitchBatch($entry) {
    switch -Regex ($entry) {
        'theme_pack|/settings/|home_widget|liquid_glass' { 2; break }
        'course_schedule|/schedule/' { 3; break }
        'academic|erke|edu_grade|exam_schedule' { 4; break }
        'scam_report|my_content' { 5; break }
        'water_section' { 6; break }
        '/poll/' { 7; break }
        'teacher_governance' { 9; break }
        '/competition/' { 10; break }
        'exam_paper' { 11; break }
        'announcement' { 12; break }
        'emoji' { 13; break }
        '/ai[/_]|managed_bot' { 14; break }
        '/feedback/' { 15; break }
        default { 1 }
    }
}

Push-Location $root
try {
    $routes = @(Get-Content (Join-Path $report 'server.log') | ForEach-Object {
        if ($_ -match '^\[GIN-debug\]\s+(?<method>[A-Z]+)\s+(?<path>/\S*)\s+-->\s+(?<handler>\S+)\s+\(\d+ handlers?\)') {
            [pscustomobject]@{ method = $Matches.method; path = $Matches.path; handler = $Matches.handler }
        }
    })
    if (!$routes.Count) { throw 'No Gin routes in server.log.' }
    $routes | Export-Csv (Join-Path $report 'routes.csv') -Encoding utf8BOM
    $handlers = @{}
    foreach ($line in rg -n '^func\s+(\([^)]*\)\s+)?[A-Z]\w*\(' server/internal/handlers -g '*.go' -g '!**/*_test.go') {
        if ($line -match '^(?<file>[^:]+):\d+:func\s+(?:\(\w+\s+\*?(?<receiver>\w+)\)\s+)?(?<name>\w+)\(') {
            $key = if ($Matches.receiver) { "$($Matches.receiver).$($Matches.name)" } else { $Matches.name }
            $handlers[$key] = "$($Matches.file.Replace('\','/')):$($Matches.name)"
        }
    }
    $ledger = @(
        foreach ($route in $routes) {
            $api = "$($route.method) $($route.path)"
            $batch = Get-ApiBatch $route.path
            $role = if ($access.Super.Keys.Where({ $api -cmatch $_ }).Count) { 'super_admin' }
                elseif ($access.Admin.Keys.Where({ $api -cmatch $_ }).Count) { 'admin' } else { '' }
            $kind = if ($role) { 'admin' } elseif ($route.method -in 'GET','HEAD','OPTIONS') { 'display' } else { 'write' }
            $name = $route.handler -replace '^shenliyuan/internal/handlers\.', '' -replace '^\(\*(\w+)\)', '$1' -replace '-fm$', ''
            $handler = $handlers[$name]
            $status = if ($handler -and $batch -ne 17) { 'mapped' } else { 'unmapped' }
            $note = if ($batch -eq 17) { '跨模块或归属待核对' } elseif (!$handler) { '运行时符号已记录，源文件待核对' } else { '' }
            if (!$handler) { $handler = $route.handler }
            New-Row $batch $kind $status '' $api $handler $role $note
        }
        foreach ($line in rg -n '\b(?:SwitchListTile|Switch|CupertinoSwitch|SettingsSwitch|LiquidGlassSwitch|AiModeSwitch|ToggleButtons|SegmentedButton<bool>|_buildPermSwitch|_rowSwitch)(?:\.adaptive)?\s*\(' client/lib -g '*.dart') {
            if ($line -notmatch '^(?<file>[^:]+):(?<line>\d+):(?<code>.*)$') { continue }
            $file, $number, $code = $Matches.file.Replace('\','/'), $Matches.line, $Matches.code
            if ($code.TrimStart() -match '^(const\s+\w+\(\{|//|Widget\s+_\w+Switch\()' -or
                $file -match '/(settings_switch|liquid_glass_switch)\.dart$' -or
                $code -match 'Switch\(value: value, onChanged: onChanged\)|child: SwitchListTile\($') { continue }
            $entry = "${file}:$number"
            $status = if ($file -match 'theme_workshop_samples|liquid_glass_qa_screen') { 'preview' } else { 'unmapped' }
            if ($file -match 'ai_feature_settings_screen\.dart$') {
                foreach ($label in rg -o -r '$1' 'AIFeatureFlag\.(\w+) => ' $file | Select-Object -Unique) {
                    New-Row 14 'switch' $status $entry 'local' '' '' $label
                }
            } else {
                New-Row (Get-SwitchBatch $entry) 'switch' $status $entry
            }
        }
        $placeholders = @(
            @('client/lib/providers/ai_assistant_provider.dart:533','基础设施测试中，暂未开放真实问答'),
            @('client/lib/screens/ai/ai_assistant_screen.dart:1233','毕业助手内测版本暂未开放'),
            @('client/lib/screens/ai/campus_personal_data_permission_screen.dart:177','部分个人数据授权未开放'),
            @('client/lib/screens/ai/campus_personal_data_permission_screen.dart:225','AI 主动刷新教务未开放'),
            @('client/lib/features/ai_runtime/ai_feature_flags.dart:62','AI 受内测开关限制'),
            @('client/lib/features/emoji/presentation/emoji_download_screen.dart:614','官方表情下载暂未开放'),
            @('client/lib/features/theme_pack/theme_store_repository.dart:20','主题商城支持关闭态'),
            @('client/lib/screens/scam_report_placeholder.dart:1','骗子曝光开发中占位页，盘点时无入口引用'),
            @('client/lib/screens/managed_bot_screen.dart:1052','自动评论按服务端开关显示未开放'),
            @('client/lib/screens/managed_bot_screen.dart:1072','自动发帖按服务端开关显示未开放'),
            @('client/lib/screens/edu_grade_screen.dart:299','研究生成绩与学业总览未开放'),
            @('client/lib/screens/edu_grade_screen.dart:1172','研究生官方 GPA 未开放'),
            @('client/lib/screens/edu_grade_screen.dart:1177','研究生学分要求未开放')
        )
        foreach ($item in $placeholders) { New-Row (Get-SwitchBatch $item[0]) 'display' 'out_of_scope' $item[0] '' '' '' "$($item[1])。待维护者签字。" }
        foreach ($file in 'theme_import_screen.dart','theme_workshop_samples.dart') {
            foreach ($line in rg -n 'on(?:Pressed|Tap|Changed):\s*\([^)]*\)\s*\{\s*\}' "client/lib/features/theme_pack/$file") {
                $number = ($line -split ':', 2)[0]
                New-Row 2 'preview' 'preview' "client/lib/features/theme_pack/${file}:$number" 'local' '' '' '预览示意控件'
            }
        }
    )
    $ledger | Export-Csv (Join-Path $report 'ledger.csv') -Encoding utf8BOM
    $ledger | Group-Object batch | Sort-Object { [int]$_.Name } | Select-Object Name,Count
} finally { Pop-Location }
