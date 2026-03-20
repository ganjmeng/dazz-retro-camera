package com.retrocam.app.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import com.retrocam.app.MainActivity
import com.retrocam.app.R

data class WidgetCamera(val id: String, val label: String)

private val kWidgetCameraOrder = listOf(
    WidgetCamera("fxn_r", "FXN R"),
    WidgetCamera("cpm35", "CPM35"),
    WidgetCamera("inst_sqc", "INST SQC"),
    WidgetCamera("grd_r", "GRD R"),
    WidgetCamera("ccd_r", "CCD R"),
    WidgetCamera("bw_classic", "BW"),
)

private fun cameraLaunchIntent(context: Context, cameraId: String): PendingIntent {
    val uri = Uri.parse("dazzretro://widget/camera?cameraId=$cameraId")
    val intent = Intent(Intent.ACTION_VIEW, uri, context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
    }
    return PendingIntent.getActivity(
        context,
        cameraId.hashCode(),
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun bindCameraButtons(
    context: Context,
    views: RemoteViews,
    buttonIds: List<Int>,
    cameras: List<WidgetCamera>,
) {
    buttonIds.forEachIndexed { index, viewId ->
        val camera = cameras.getOrNull(index)
        if (camera == null) {
            views.setViewVisibility(viewId, android.view.View.GONE)
        } else {
            views.setViewVisibility(viewId, android.view.View.VISIBLE)
            views.setTextViewText(viewId, camera.label)
            views.setOnClickPendingIntent(viewId, cameraLaunchIntent(context, camera.id))
        }
    }
}

abstract class BaseCameraWidgetProvider(
    private val layoutId: Int,
    private val buttonIds: List<Int>,
    private val cameras: List<WidgetCamera>,
) : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { appWidgetId ->
            val views = RemoteViews(context.packageName, layoutId)
            bindCameraButtons(context, views, buttonIds, cameras)
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    fun notifyAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, javaClass))
        onUpdate(context, manager, ids)
    }
}

class DazzCameraSmallWidgetProvider : BaseCameraWidgetProvider(
    R.layout.dazz_widget_small,
    listOf(R.id.camera_1),
    kWidgetCameraOrder.take(1),
)

class DazzCameraMediumWidgetProvider : BaseCameraWidgetProvider(
    R.layout.dazz_widget_medium,
    listOf(R.id.camera_1, R.id.camera_2, R.id.camera_3, R.id.camera_4),
    kWidgetCameraOrder.take(4),
)

class DazzCameraLargeWidgetProvider : BaseCameraWidgetProvider(
    R.layout.dazz_widget_large,
    listOf(
        R.id.camera_1,
        R.id.camera_2,
        R.id.camera_3,
        R.id.camera_4,
        R.id.camera_5,
        R.id.camera_6,
    ),
    kWidgetCameraOrder,
)
