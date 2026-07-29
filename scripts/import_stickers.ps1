param(
    [string]$SourceRoot = "C:\Users\haha\Desktop\表情包",
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

# 表情包导入器：客户端只保留缩略图，高清 PNG/GIF 嵌入服务端二进制。
# GHF 会混淆 GIF 的文件头和调色板；动态文件还包含一个无法标准解码的封面帧。
$groupDefinitions = @(
    @{
        Folder = "mingfengfneg1"
        Id = "mingfeng-daily"
        Name = "明风·日常"
        Metadata = $null
        Dynamic = $false
        # 该包没有 jtmp 元数据，名称与顺序按源包详情页恢复。
        Order = @(
            "aad70d8d064f9eb79286c1393490716c",
            "d0deb840abc781f414c7ad6824407964",
            "1c704494bbb89fce27681425cffbe6fa",
            "36286e5249dbbd659981ca530e21c047",
            "0eeed98ece4e89243db9dea7ccd796fd",
            "4535efdfbdc938e7c225528e8915285b",
            "d0ccdc6d8c3e941529e797b4d8d5ef85",
            "5d9aa5f7f3b304bf7cffa81cdde8901c",
            "6d65948c4146fc8a669b9bb10f3832e6",
            "d931ab4696e4003b744092c1acd3b6c8",
            "2d094a6c0e1ac32d31a65286eb141a57",
            "bf4fdc61f3162854bd1e8f80114f0624",
            "6608d1dacfcde27f87f7d3852330d0fb",
            "986e5bd2a4b13d23b32416c046ecb068",
            "f824b5b93951ea809e59bab466114f71",
            "f05144bf668463d3f2742765d6f8da14"
        )
        Labels = @{
            "aad70d8d064f9eb79286c1393490716c" = "亲亲"
            "d0deb840abc781f414c7ad6824407964" = "粘"
            "1c704494bbb89fce27681425cffbe6fa" = "认真"
            "36286e5249dbbd659981ca530e21c047" = "抱"
            "0eeed98ece4e89243db9dea7ccd796fd" = "敢这么说话"
            "4535efdfbdc938e7c225528e8915285b" = "花花"
            "d0ccdc6d8c3e941529e797b4d8d5ef85" = "看手机"
            "5d9aa5f7f3b304bf7cffa81cdde8901c" = "长条"
            "6d65948c4146fc8a669b9bb10f3832e6" = "捏"
            "d931ab4696e4003b744092c1acd3b6c8" = "拍照"
            "2d094a6c0e1ac32d31a65286eb141a57" = "阿巴"
            "bf4fdc61f3162854bd1e8f80114f0624" = "猫"
            "6608d1dacfcde27f87f7d3852330d0fb" = "叹气"
            "986e5bd2a4b13d23b32416c046ecb068" = "苦露西"
            "f824b5b93951ea809e59bab466114f71" = "辛苦了"
            "f05144bf668463d3f2742765d6f8da14" = "疑惑"
        }
    },
    @{ Folder = "mingfengfneg2"; Id = "mingfeng-ovo"; Name = "明风 OvO"; Metadata = "237834.jtmp"; Dynamic = $true; Order = $null; Labels = $null },
    @{ Folder = "mingfengfneg3"; Id = "mingfengfeng"; Name = "明风风"; Metadata = "234400.jtmp"; Dynamic = $false; Order = $null; Labels = $null },
    @{ Folder = "mingfengfneg4"; Id = "mingfeng"; Name = "明风"; Metadata = "234044.jtmp"; Dynamic = $false; Order = $null; Labels = $null }
)

$ghfHeader = [byte[]](0x47, 0x48, 0x46, 0x39, 0x39, 0x60)
$gifHeader = [byte[]](0x47, 0x49, 0x46, 0x38, 0x39, 0x61)

function Test-BytePrefix {
    param([byte[]]$Bytes, [int]$Offset, [byte[]]$Expected)

    if ($Offset -lt 0 -or $Offset + $Expected.Length -gt $Bytes.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Bytes[$Offset + $index] -ne $Expected[$index]) {
            return $false
        }
    }
    return $true
}

function Convert-GhfToGif {
    param([byte[]]$SourceBytes, [string]$SourcePath)

    if (-not (Test-BytePrefix $SourceBytes 0 $ghfHeader)) {
        throw "不支持的 GHF 文件头：$SourcePath"
    }
    if ($SourceBytes.Length -lt 13) {
        throw "GHF 文件过短：$SourcePath"
    }

    $decoded = [byte[]]$SourceBytes.Clone()
    for ($index = 1; $index -lt 13; $index += 2) {
        $decoded[$index] = $decoded[$index] -bxor 0x01
    }
    if (-not (Test-BytePrefix $decoded 0 $gifHeader)) {
        throw "GHF 文件头解码失败：$SourcePath"
    }

    $packedFields = $decoded[10]
    $globalColorTableLength = if (($packedFields -band 0x80) -ne 0) {
        [int](3 * [Math]::Pow(2, (($packedFields -band 0x07) + 1)))
    } else {
        0
    }
    $prefixEnd = 13 + $globalColorTableLength
    if ($prefixEnd -gt $decoded.Length) {
        throw "GHF 全局调色板越界：$SourcePath"
    }
    for ($index = 13; $index -lt $prefixEnd; $index += 2) {
        $decoded[$index] = $decoded[$index] -bxor 0x01
    }

    # 动态 GHF 在调色板后还混淆了 NETSCAPE 循环扩展，并带有一个损坏的封面帧。
    $encodedLoopExtension = [byte[]](0x20, 0xFF, 0x0A)
    if (-not (Test-BytePrefix $SourceBytes $prefixEnd $encodedLoopExtension)) {
        return ,$decoded
    }

    $loopExtensionLength = 19
    $loopExtensionEnd = $prefixEnd + $loopExtensionLength
    if ($loopExtensionEnd -gt $decoded.Length) {
        throw "GHF 循环扩展越界：$SourcePath"
    }
    $firstOddIndex = if (($prefixEnd % 2) -eq 1) { $prefixEnd } else { $prefixEnd + 1 }
    for ($index = $firstOddIndex; $index -lt $loopExtensionEnd; $index += 2) {
        $decoded[$index] = $decoded[$index] -bxor 0x01
    }

    $standardLoopExtension = [byte[]](0x21, 0xFF, 0x0B)
    if (-not (Test-BytePrefix $decoded $prefixEnd $standardLoopExtension)) {
        throw "GHF 循环扩展解码失败：$SourcePath"
    }

    $firstUsableFrame = -1
    for ($index = $loopExtensionEnd; $index -lt $decoded.Length - 9; $index++) {
        $isGraphicControlExtension =
            $decoded[$index] -eq 0x21 -and
            $decoded[$index + 1] -eq 0xF9 -and
            $decoded[$index + 2] -eq 0x04 -and
            $decoded[$index + 7] -eq 0x00 -and
            $decoded[$index + 8] -eq 0x2C
        if ($isGraphicControlExtension) {
            $firstUsableFrame = $index
            break
        }
    }
    if ($firstUsableFrame -lt 0) {
        throw "GHF 中未找到可用动画帧：$SourcePath"
    }

    $output = [byte[]]::new($loopExtensionEnd + $decoded.Length - $firstUsableFrame)
    [System.Array]::Copy($decoded, 0, $output, 0, $loopExtensionEnd)
    [System.Array]::Copy(
        $decoded,
        $firstUsableFrame,
        $output,
        $loopExtensionEnd,
        $decoded.Length - $firstUsableFrame
    )
    return ,$output
}

function Get-GifFrameCount {
    param([byte[]]$Bytes, [string]$SourcePath)

    $stream = [System.IO.MemoryStream]::new($Bytes, $false)
    $image = $null
    try {
        $image = [System.Drawing.Image]::FromStream($stream)
        if ($image.Width -ne 300 -or $image.Height -ne 300) {
            throw "GIF 尺寸应为 300x300，实际为 $($image.Width)x$($image.Height)：$SourcePath"
        }
        return $image.GetFrameCount([System.Drawing.Imaging.FrameDimension]::Time)
    } catch {
        throw "GIF 解码校验失败：$SourcePath；$($_.Exception.Message)"
    } finally {
        if ($null -ne $image) { $image.Dispose() }
        $stream.Dispose()
    }
}

$clientRoot = Join-Path $ProjectRoot "client\assets\images\stickers"
$serverRoot = Join-Path $ProjectRoot "server\internal\handlers\sticker_assets"
$clientCatalogPath = Join-Path $ProjectRoot "client\lib\widgets\emoji\sticker_catalog.dart"
New-Item -ItemType Directory -Force -Path $clientRoot, $serverRoot | Out-Null

$catalog = [System.Collections.Generic.List[object]]::new()

foreach ($definition in $groupDefinitions) {
    $sourceGroup = Join-Path $SourceRoot $definition.Folder
    if (-not (Test-Path -LiteralPath $sourceGroup -PathType Container)) {
        throw "缺少表情包目录：$sourceGroup"
    }

    $clientGroup = Join-Path $clientRoot $definition.Id
    New-Item -ItemType Directory -Force -Path $clientGroup | Out-Null

    $labels = @{}
    if ($definition.Labels) {
        foreach ($id in $definition.Labels.Keys) {
            $labels[[string]$id] = [string]$definition.Labels[$id]
        }
    }
    $orderedIds = [System.Collections.Generic.List[string]]::new()
    if ($definition.Order) {
        foreach ($id in $definition.Order) {
            $orderedIds.Add([string]$id)
        }
    } elseif ($definition.Metadata) {
        $metadataPath = Join-Path $sourceGroup $definition.Metadata
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($image in $metadata.imgs) {
            $orderedIds.Add([string]$image.id)
            $labels[[string]$image.id] = [string]$image.name
        }
    } else {
        Get-ChildItem -LiteralPath $sourceGroup -Filter "*_thu.png" |
            Sort-Object Name |
            ForEach-Object { $orderedIds.Add(($_.BaseName -replace "_thu$", "")) }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $position = 0
    foreach ($id in $orderedIds) {
        $position++
        $thumbnailSource = Join-Path $sourceGroup "${id}_thu.png"
        if (-not (Test-Path -LiteralPath $thumbnailSource -PathType Leaf)) {
            throw "缺少缩略图：$thumbnailSource"
        }
        [System.IO.File]::Copy($thumbnailSource, (Join-Path $clientGroup "$id.png"), $true)

        $originalSource = Join-Path $sourceGroup $id
        $previewSource = Join-Path $sourceGroup "${id}_aio.png"
        if (Test-Path -LiteralPath $originalSource -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($originalSource)
            $bytes = Convert-GhfToGif $bytes $originalSource
            $frameCount = Get-GifFrameCount $bytes $originalSource
            if ($definition.Dynamic -and $frameCount -lt 2) {
                throw "动态表情帧数不足：$originalSource；实际为 $frameCount 帧"
            }
            $fileName = "$id.gif"
            [System.IO.File]::WriteAllBytes((Join-Path $serverRoot $fileName), $bytes)
            $mimeType = "image/gif"
        } else {
            $imageSource = if (Test-Path -LiteralPath $previewSource -PathType Leaf) {
                $previewSource
            } else {
                $thumbnailSource
            }
            $fileName = "$id.png"
            [System.IO.File]::Copy($imageSource, (Join-Path $serverRoot $fileName), $true)
            $mimeType = "image/png"
        }

        $label = if ($labels.ContainsKey($id)) { $labels[$id] } else { "表情 $position" }
        $items.Add([ordered]@{
            id = $id
            label = $label
            thumbnail_asset = "assets/images/stickers/$($definition.Id)/$id.png"
            file = $fileName
            mime_type = $mimeType
        })
    }

    if ($items.Count -ne 16) {
        throw "表情分组 $($definition.Name) 应为 16 个，实际为 $($items.Count) 个"
    }
    $catalog.Add([ordered]@{ id = $definition.Id; name = $definition.Name; items = $items })
}

$catalogJson = $catalog | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText(
    (Join-Path $serverRoot "catalog.json"),
    $catalogJson,
    [System.Text.UTF8Encoding]::new($false)
)

$dart = [System.Text.StringBuilder]::new()
[void]$dart.AppendLine("// 本文件由 scripts/import_stickers.ps1 生成，请勿手工维护。")
[void]$dart.AppendLine("class AppSticker {")
[void]$dart.AppendLine("  final String id;")
[void]$dart.AppendLine("  final String label;")
[void]$dart.AppendLine("  final String thumbnailAsset;")
[void]$dart.AppendLine("")
[void]$dart.AppendLine("  const AppSticker({required this.id, required this.label, required this.thumbnailAsset});")
[void]$dart.AppendLine("}")
[void]$dart.AppendLine("")
[void]$dart.AppendLine("class AppStickerGroup {")
[void]$dart.AppendLine("  final String id;")
[void]$dart.AppendLine("  final String name;")
[void]$dart.AppendLine("  final List<AppSticker> items;")
[void]$dart.AppendLine("")
[void]$dart.AppendLine("  const AppStickerGroup({required this.id, required this.name, required this.items});")
[void]$dart.AppendLine("}")
[void]$dart.AppendLine("")
[void]$dart.AppendLine("const List<AppStickerGroup> appStickerGroups = [")
foreach ($group in $catalog) {
    [void]$dart.AppendLine("  AppStickerGroup(id: '$($group.id)', name: '$($group.name)', items: [")
    foreach ($item in $group.items) {
        $safeLabel = ([string]$item.label).Replace("'", "\'")
        [void]$dart.AppendLine("    AppSticker(id: '$($item.id)', label: '$safeLabel', thumbnailAsset: '$($item.thumbnail_asset)'),")
    }
    [void]$dart.AppendLine("  ]),")
}
[void]$dart.AppendLine("] ;")
[void]$dart.AppendLine("")
[void]$dart.AppendLine("AppSticker? appStickerById(String? id) {")
[void]$dart.AppendLine("  final normalized = id?.trim();")
[void]$dart.AppendLine("  if (normalized == null || normalized.isEmpty) return null;")
[void]$dart.AppendLine("  for (final group in appStickerGroups) {")
[void]$dart.AppendLine("    for (final sticker in group.items) {")
[void]$dart.AppendLine("      if (sticker.id == normalized) return sticker;")
[void]$dart.AppendLine("    }")
[void]$dart.AppendLine("  }")
[void]$dart.AppendLine("  return null;")
[void]$dart.AppendLine("}")
[System.IO.File]::WriteAllText($clientCatalogPath, $dart.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "已导入 $((($catalog | ForEach-Object { $_.items.Count }) | Measure-Object -Sum).Sum) 个表情。"
