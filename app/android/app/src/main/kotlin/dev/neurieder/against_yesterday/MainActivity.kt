// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

package dev.neurieder.against_yesterday

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the app's platform channels:
 *
 *  * writing exported GPX tracks into the public Downloads folder (API 29+
 *    via `MediaStore.Downloads`, no permission; API 24–28 write the file
 *    directly and therefore ask for the legacy `WRITE_EXTERNAL_STORAGE` grant
 *    first);
 *  * keeping the recording foreground service (`RecordingForegroundService`)
 *    matched to the live GPS stream while the screen is off.
 */
class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingWrite: Pair<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val name = call.argument<String>("name")
                val contents = call.argument<String>("contents")
                if (name.isNullOrBlank() || contents == null) {
                    result.error("bad-args", "name and contents are required.", null)
                    return@setMethodCallHandler
                }
                saveToDownloads(name, contents, result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RECORDING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRecording" -> startRecordingService(result)
                    "stopRecording" -> {
                        RecordingForegroundService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Starts the location foreground service, failing with a typed channel
     * error instead of crashing the run when Android will not allow it. The
     * Dart side maps the code back onto a user-visible reason and surfaces it,
     * never assuming screen-off protection it does not have.
     */
    private fun startRecordingService(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error(
                "permission-denied",
                "Location permission is missing.",
                null,
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val manager = getSystemService(LocationManager::class.java)
            if (!manager.isLocationEnabled) {
                result.error(
                    "location-disabled",
                    "Location services are off.",
                    null,
                )
                return
            }
        }
        try {
            RecordingForegroundService.start(this)
            result.success(null)
        } catch (error: SecurityException) {
            result.error(
                "security",
                error.message ?: "Location permission was revoked.",
                null,
            )
        } catch (error: RuntimeException) {
            // API 31+ throws ForegroundServiceStartNotAllowedException for a
            // start the app's state does not permit; the class only exists on
            // 31+, so match it by name to stay safe on older runtimes.
            if (error.javaClass.name ==
                "android.app.ForegroundServiceStartNotAllowedException"
            ) {
                result.error(
                    "not-allowed",
                    "Android refused to start the recording service "
                        + "from the background.",
                    null,
                )
            } else {
                result.error(
                    "start-failed",
                    error.message ?: "The recording service could not start.",
                    null,
                )
            }
        }
    }

    private fun saveToDownloads(
        name: String,
        contents: String,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            // Ask once, then finish the write from onRequestPermissionsResult.
            pendingResult = result
            pendingWrite = name to contents
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                STORAGE_REQUEST,
            )
            return
        }
        finishWrite(name, contents, result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != STORAGE_REQUEST) return
        val result = pendingResult
        val write = pendingWrite
        pendingResult = null
        pendingWrite = null
        if (result == null || write == null) return
        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            finishWrite(write.first, write.second, result)
        } else {
            result.error(
                "permission-denied",
                "Storage permission is required to save to Downloads.",
                null,
            )
        }
    }

    private fun finishWrite(
        name: String,
        contents: String,
        result: MethodChannel.Result,
    ) {
        try {
            val location = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                writeViaMediaStore(name, contents)
            } else {
                writeLegacy(name, contents)
            }
            if (location.isNullOrEmpty()) {
                result.error("write-failed", "Could not write to Downloads.", null)
            } else {
                result.success(location)
            }
        } catch (error: Exception) {
            result.error(
                "write-failed",
                error.message ?: "Could not write to Downloads.",
                null,
            )
        }
    }

    private fun writeViaMediaStore(name: String, contents: String): String? {
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, MIME_TYPE_GPX)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return null
        try {
            val stream = resolver.openOutputStream(uri) ?: return null
            stream.use { it.write(contents.toByteArray(Charsets.UTF_8)) }
        } finally {
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        }
        return "${Environment.DIRECTORY_DOWNLOADS}/$name"
    }

    private fun writeLegacy(name: String, contents: String): String? {
        val directory =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!directory.exists() && !directory.mkdirs()) return null
        val file = uniqueFile(directory, name)
        file.writeText(contents, Charsets.UTF_8)
        return file.absolutePath
    }

    /** Appends ` (n)` before the extension until the name is free. */
    private fun uniqueFile(directory: File, name: String): File {
        var candidate = File(directory, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var attempt = 1
        while (candidate.exists()) {
            candidate = File(directory, "$base ($attempt)$extension")
            attempt++
        }
        return candidate
    }

    private companion object {
        const val CHANNEL = "dev.neurieder.against_yesterday/files"
        const val RECORDING_CHANNEL = "dev.neurieder.against_yesterday/recording"
        const val STORAGE_REQUEST = 5416
        const val MIME_TYPE_GPX = "application/gpx+xml"
    }
}
