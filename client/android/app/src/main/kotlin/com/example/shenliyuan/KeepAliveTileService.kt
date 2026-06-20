package com.example.shenliyuan

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class KeepAliveTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val status = KeepAliveForegroundService.status(this)
        val enabled = status["enabled"] as? Boolean ?: false
        KeepAliveForegroundService.setEnabled(this, !enabled)
        updateTile()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val status = KeepAliveForegroundService.status(this)
        val enabled = status["enabled"] as? Boolean ?: false
        val running = status["serviceRunning"] as? Boolean ?: false
        tile.label = "沈理保活"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when {
                enabled && running -> "运行中"
                enabled -> "已开启"
                else -> "未开启"
            }
        }
        tile.state = if (enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }
}
